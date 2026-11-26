"""Event projections - pure handlers that turn chain events into DB rows.

Split from :mod:`apps.blockchain.services.indexer` (which owns cursor
management and fetching) so handler logic can be unit-tested and reviewed
independently of sync mechanics. Handlers must be replay-safe: the indexer
records a ProcessedEvent and the projection in one transaction, and retries
on failure.
"""

from __future__ import annotations

import hashlib
import json
import logging
from datetime import datetime, timezone as dt_timezone

from apps.commerce.models import Order
from apps.escrow.models import Escrow
from apps.marketplace.models import Listing
from apps.participants.models import Participant
from apps.reputation.models import ReputationEvent, ReputationProfile
from integrations.qorechain.client import get_evm_client
from integrations.qorechain.contracts import artifact_path, contract_address
from integrations.qorechain.contracts_base import load_abi, make_contract

logger = logging.getLogger(__name__)


def _contract(name: str):
    address = contract_address(name)
    if not address:
        return None
    w3 = get_evm_client()
    return make_contract(w3, address, load_abi(artifact_path(name)))


def _participant_for(address: str) -> Participant:
    """Get or create the participant row for a chain address (indexer-managed)."""
    address = address.lower()
    participant = Participant.objects.filter(evm_address__iexact=address).first()
    if participant:
        return participant

    try:
        from qorsdk.address import hex_to_bech32

        qor_address = hex_to_bech32(address)
    except Exception:
        qor_address = None

    short = f"{address[:6]}…{address[-4:]}"
    return Participant.objects.create(
        display_name=f"Chain account {short}",
        qor_address=qor_address,
        evm_address=address,
    )


def _wei_to_uqor(value: int) -> int:
    """EVM lane is 18-decimals; the native unit (uqor) is 6 — 1 QOR = 10^12 wei."""
    return int(value) // 10**12


# Demo catalog: display titles for the well-known fixture listings whose
# metadata URIs are placeholders (sweeft.example). Only used when the live
# fetch below fails — user-submitted metadata (hash-verified) always wins,
# and editing a title in the UI is never overwritten (backfill checks for
# the "Listing #N" placeholder).
DEMO_CATALOG = {
    "demo-laptop": {
        "title": "MacBook Pro 14",
        "description": "14-inch laptop, used in excellent condition. Ships with charger; battery health 92%.",
    },
    "demo-funded": {
        "title": "Ergonomic Desk Lamp",
        "description": "Adjustable brass desk lamp with warm LED. Ships tracked within 2 days.",
    },
    "demo-eligible": {
        "title": "Mechanical Keyboard",
        "description": "Hot-swappable 75% mechanical keyboard, silent linear switches, QMK/VIA support.",
    },
    "demo-keyboard": {
        "title": "Mechanical Keyboard",
        "description": "Hot-swappable 75% mechanical keyboard, silent linear switches.",
    },
    "demo-lamp": {
        "title": "Brass Desk Lamp",
        "description": "Vintage-style brass desk lamp, rewired and tested.",
    },
    "demo-4": {
        "title": "Smart Speaker",
        "description": "Voice-controlled smart speaker, tested with post-quantum-signed payments.",
    },
    "demo-5": {
        "title": "Wireless Earbuds",
        "description": "Noise-cancelling wireless earbuds, battery 80%.",
    },
    "demo-6": {
        "title": "4K Monitor",
        "description": "27-inch 4K display, color-calibrated, minor desk wear.",
    },
}


def _catalog_entry(uri: str) -> dict:
    """Fallback product info for demo fixture listings (display-only)."""
    base = (uri or "").rsplit("/", 1)[-1].removesuffix(".json")
    return DEMO_CATALOG.get(base, {})


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------


def _fetch_verified_metadata(uri: str, expected_hash_hex: str, *, timeout: int = 8) -> dict:
    """Fetch listing metadata and verify it against the on-chain hash.

    Returns {} when the fetch fails or the bytes do not hash to the anchored
    value — a mismatched listing keeps its placeholder title and is never
    presented as verified content.
    """
    if not uri:
        return {}
    try:
        import requests

        response = requests.get(uri, timeout=timeout)
        response.raise_for_status()
        raw = response.content
        digest = "0x" + hashlib.sha256(raw).hexdigest()
        if digest.lower() != expected_hash_hex.lower():
            logger.warning("metadata hash mismatch for %s (expected %s)", uri, expected_hash_hex)
            return {}
        return json.loads(raw)
    except Exception:
        logger.exception("could not fetch listing metadata from %s", uri)
        return {}


def _handle_listing_created(event) -> dict:
    args = event.args
    metadata_hash = "0x" + bytes(args["metadataHash"]).hex()

    # The event doesn't carry the URI; read it from the contract, then fetch
    # and verify the description against the hash the event carries.
    metadata = {}
    metadata_uri = ""
    logistics_partner = ""
    logistics_fee = 0
    try:
        listing_contract = _contract("SweeftMarketplace")
        if listing_contract is not None:
            on_chain = listing_contract.functions.getListing(int(args["listingId"])).call()
            metadata_uri = on_chain[4]
            metadata = _fetch_verified_metadata(metadata_uri, metadata_hash)
            # v4 struct: [seller, price, qty, status, uri, hash, createdAt, updatedAt, partner, fee]
            if len(on_chain) > 9:
                logistics_partner = on_chain[8] or ""
                logistics_fee = _wei_to_uqor(on_chain[9])
    except Exception:
        logger.exception("could not load listing metadata")

    # Demo fixture listings point at placeholder URIs that can never verify;
    # fall back to the display catalog so the marketplace shows real product
    # names. Hash-verified metadata above always takes precedence.
    if not metadata.get("title"):
        metadata = _catalog_entry(metadata_uri)

    listing, created = Listing.objects.update_or_create(
        on_chain_id=int(args["listingId"]),
        defaults={
            "seller": _participant_for(args["seller"]),
            "title": str(metadata.get("title") or f"Listing #{args['listingId']}")[:200],
            "description": str(metadata.get("description") or ""),
            "price_uqor": _wei_to_uqor(args["price"]),
            "quantity": int(args["quantity"]),
            "status": Listing.Status.ACTIVE,
            "metadata_hash": metadata_hash,
            "created_tx": event.tx_hash,
            "created_block": event.block_number,
            "logistics_partner_address": logistics_partner,
            "logistics_fee_uqor": logistics_fee,
            "delivery_type": "physical" if logistics_partner else "digital",
        },
    )
    return {"listing_id": listing.on_chain_id, "created": created}


def _handle_listing_purchased(event) -> dict:
    args = event.args
    listing = Listing.objects.filter(on_chain_id=int(args["listingId"])).first()
    buyer = _participant_for(args["buyer"])
    seller = _participant_for(args["seller"])
    escrow_id = int(args["escrowId"])
    price = _wei_to_uqor(args["price"])

    order, _ = Order.objects.get_or_create(
        reference=f"SW-{escrow_id:06d}",
        defaults={
            "listing": listing,
            "buyer": buyer,
            "seller": seller,
            "quantity": 1,
            "unit_price_uqor": price,
            "total_uqor": price,
            "state": Order.State.ESCROW_CREATED,
        },
    )

    if listing:
        listing.quantity = max(listing.quantity - 1, 0)
        if listing.quantity == 0:
            listing.status = Listing.Status.SOLD
        listing.save(update_fields=["quantity", "status", "updated_at"])

    return {"escrow_id": escrow_id, "order": order.reference}


def _handle_listing_cancelled(event) -> dict:
    listing = Listing.objects.filter(on_chain_id=int(event.args["listingId"])).first()
    if listing:
        listing.status = Listing.Status.CANCELLED
        listing.save(update_fields=["status", "updated_at"])
    return {"listing_id": event.args["listingId"]}


def _handle_escrow_created(event) -> dict:
    args = event.args
    escrow_id = int(args["escrowId"])
    buyer = _participant_for(args["buyer"])
    seller = _participant_for(args["seller"])
    amount = _wei_to_uqor(args["amount"])

    order = Order.objects.filter(reference=f"SW-{escrow_id:06d}").first()
    if order is None:
        order = Order.objects.create(
            reference=f"SW-{escrow_id:06d}",
            buyer=buyer,
            seller=seller,
            quantity=1,
            unit_price_uqor=amount,
            total_uqor=amount,
            state=Order.State.ESCROW_CREATED,
        )

    escrow, created = Escrow.objects.update_or_create(
        on_chain_id=escrow_id,
        defaults={
            "order": order,
            "buyer": buyer,
            "seller": seller,
            "amount_uqor": amount,
            "delivery_deadline": datetime.fromtimestamp(int(args["deliveryDeadline"]), tz=dt_timezone.utc),
            "create_tx": event.tx_hash,
        },
    )
    # Hydrate logistics fields from the Vault struct (v4 appends them at the end)
    try:
        vault_c = _contract("SweeftVault")
        if vault_c is not None:
            on_chain = vault_c.functions.getEscrow(escrow_id).call()
            if len(on_chain) > 11:
                escrow.logistics_partner_address = on_chain[11] or ""
                escrow.logistics_amount_uqor = _wei_to_uqor(on_chain[12])
                escrow.delivery_type = "physical" if on_chain[11] else "digital"
                escrow.save(update_fields=["logistics_partner_address", "logistics_amount_uqor", "delivery_type"])
    except Exception:
        logger.exception("could not load logistics allocation for escrow %s", escrow_id)
    return {"escrow_id": escrow_id, "created": created}


def _handle_escrow_funded(event) -> dict:
    escrow = Escrow.objects.filter(on_chain_id=int(event.args["escrowId"])).first()
    if escrow:
        escrow.state = Escrow.State.FUNDED
        escrow.fund_tx = event.tx_hash
        escrow.save(update_fields=["state", "fund_tx", "updated_at"])
        escrow.order.state = Order.State.FUNDED
        escrow.order.save(update_fields=["state", "updated_at"])
    return {"escrow_id": event.args["escrowId"]}


def _handle_marked_delivered(event) -> dict:
    escrow = Escrow.objects.filter(on_chain_id=int(event.args["escrowId"])).first()
    if escrow:
        escrow.state = Escrow.State.DELIVERED
        escrow.save(update_fields=["state", "updated_at"])
    return {"escrow_id": event.args["escrowId"]}


def _handle_receipt_confirmed(event) -> dict:
    escrow = Escrow.objects.filter(on_chain_id=int(event.args["escrowId"])).first()
    if escrow:
        escrow.state = Escrow.State.RELEASE_ELIGIBLE
        escrow.save(update_fields=["state", "updated_at"])
    return {"escrow_id": event.args["escrowId"]}


def _handle_evidence_attested(event) -> dict:
    escrow = Escrow.objects.filter(on_chain_id=int(event.args["escrowId"])).first()
    if escrow:
        escrow.state = Escrow.State.RELEASE_ELIGIBLE
        escrow.save(update_fields=["state", "updated_at"])
        ReputationEvent.objects.get_or_create(
            escrow=escrow,
            participant=escrow.seller,
            kind=ReputationEvent.Kind.FULFILMENT_VERIFIED,
            defaults={"on_chain_tx": event.tx_hash},
        )
        _recompute(escrow.seller)
    return {"escrow_id": event.args["escrowId"]}


def _handle_funds_released(event) -> dict:
    args = event.args
    escrow = Escrow.objects.filter(on_chain_id=int(args["escrowId"])).first()
    if escrow:
        escrow.state = Escrow.State.COMPLETED
        escrow.release_tx = event.tx_hash
        # v5 emitted `pqcNonce`, v6 emits `nonce` (the nonce just consumed).
        escrow.pqc_nonce = int(args.get("pqcNonce", args.get("nonce", 0))) + 1
        escrow.save(update_fields=["state", "release_tx", "pqc_nonce", "updated_at"])
        escrow.order.state = Order.State.COMPLETED
        escrow.order.save(update_fields=["state", "updated_at"])

        for participant in (escrow.buyer, escrow.seller):
            ReputationEvent.objects.get_or_create(
                escrow=escrow,
                participant=participant,
                kind=ReputationEvent.Kind.ESCROW_COMPLETED,
                defaults={"on_chain_tx": event.tx_hash},
            )
            _recompute(participant)
    return {"escrow_id": args["escrowId"]}


def _handle_escrow_refunded(event) -> dict:
    args = event.args
    escrow = Escrow.objects.filter(on_chain_id=int(args["escrowId"])).first()
    if escrow:
        escrow.state = Escrow.State.REFUNDED
        escrow.refund_tx = event.tx_hash
        # v5 emitted `pqcNonce`, v6 emits `nonce` (the nonce just consumed).
        escrow.pqc_nonce = int(args.get("pqcNonce", args.get("nonce", 0))) + 1
        escrow.save(update_fields=["state", "refund_tx", "pqc_nonce", "updated_at"])
        escrow.order.state = Order.State.CANCELLED
        escrow.order.save(update_fields=["state", "updated_at"])
        ReputationEvent.objects.get_or_create(
            escrow=escrow,
            participant=escrow.buyer,
            kind=ReputationEvent.Kind.ESCROW_REFUNDED,
            defaults={"on_chain_tx": event.tx_hash},
        )
    return {"escrow_id": args["escrowId"]}


def _recompute(participant: Participant) -> None:
    profile, _ = ReputationProfile.objects.get_or_create(participant=participant)
    completed = ReputationEvent.objects.filter(
        participant=participant, kind=ReputationEvent.Kind.ESCROW_COMPLETED
    ).count()
    refunded = ReputationEvent.objects.filter(
        participant=participant, kind=ReputationEvent.Kind.ESCROW_REFUNDED
    ).count()
    verified = ReputationEvent.objects.filter(
        participant=participant, kind=ReputationEvent.Kind.FULFILMENT_VERIFIED
    ).count()

    profile.total_transactions = completed + refunded
    profile.successful_transactions = completed
    profile.cancelled_transactions = refunded
    profile.verified_fulfilments = verified
    profile.recompute_trust_score()
    profile.save()


# ---------------------------------------------------------------------------
# Fees and disputes
# ---------------------------------------------------------------------------


def _handle_fee_collected(event) -> dict:
    args = event.args
    escrow = Escrow.objects.filter(on_chain_id=int(args["escrowId"])).first()
    if escrow:
        escrow.fee_treasury_uqor = _wei_to_uqor(args["treasuryShare"])
        escrow.fee_dispute_uqor = _wei_to_uqor(args["disputeShare"])
        escrow.save(update_fields=["fee_treasury_uqor", "fee_dispute_uqor", "updated_at"])
    return {"escrow_id": args["escrowId"]}


def _handle_vault_dispute_raised(event) -> dict:
    escrow = Escrow.objects.filter(on_chain_id=int(event.args["escrowId"])).first()
    if escrow:
        escrow.state = Escrow.State.DISPUTED
        escrow.save(update_fields=["state", "updated_at"])
    return {"escrow_id": event.args["escrowId"]}


def _handle_dispute_resolved(event) -> dict:
    """Vault-side resolution (board settlement). Completions count for Cred."""
    args = event.args
    escrow = Escrow.objects.filter(on_chain_id=int(args["escrowId"])).first()
    if escrow is None:
        return {"escrow_id": args["escrowId"]}
    release = bool(args["releaseToSeller"])

    escrow.state = Escrow.State.COMPLETED if release else Escrow.State.REFUNDED
    escrow.save(update_fields=["state", "updated_at"])
    escrow.order.state = Order.State.COMPLETED if release else Order.State.CANCELLED
    escrow.order.save(update_fields=["state", "updated_at"])

    if release:
        for participant in (escrow.buyer, escrow.seller):
            ReputationEvent.objects.get_or_create(
                escrow=escrow,
                participant=participant,
                kind=ReputationEvent.Kind.ESCROW_COMPLETED,
                defaults={"on_chain_tx": event.tx_hash, "note": "dispute resolution"},
            )
            _recompute(participant)
    else:
        ReputationEvent.objects.get_or_create(
            escrow=escrow,
            participant=escrow.buyer,
            kind=ReputationEvent.Kind.ESCROW_REFUNDED,
            defaults={"on_chain_tx": event.tx_hash, "note": "dispute resolution"},
        )
        _recompute(escrow.buyer)
    return {"escrow_id": args["escrowId"], "release_to_seller": release}


def _handle_staked(event) -> dict:
    from apps.governance.models import ResolverProfile

    participant = _participant_for(event.args["account"])
    profile, _ = ResolverProfile.objects.get_or_create(participant=participant)
    profile.staked_uqor = _wei_to_uqor(event.args["total"])
    profile.save(update_fields=["staked_uqor", "updated_at"])
    return {"resolver": event.args["account"]}


def _handle_stake_withdrawn(event) -> dict:
    from apps.governance.models import ResolverProfile

    participant = Participant.objects.filter(evm_address__iexact=event.args["account"].lower()).first()
    if participant:
        profile, _ = ResolverProfile.objects.get_or_create(participant=participant)
        profile.staked_uqor = 0
        profile.save(update_fields=["staked_uqor", "updated_at"])
    return {"resolver": event.args["account"]}


def _handle_dispute_opened(event) -> dict:
    from datetime import datetime, timezone as dt_timezone

    from apps.governance.models import Dispute

    args = event.args
    escrow = Escrow.objects.filter(on_chain_id=int(args["escrowId"])).first()
    if escrow is None:
        return {"dispute_id": args["disputeId"]}

    dispute, _ = Dispute.objects.update_or_create(
        on_chain_id=int(args["disputeId"]),
        defaults={
            "escrow": escrow,
            "raiser": _participant_for(args["raiser"]),
            "joining_ends_at": datetime.fromtimestamp(int(args["joinEndsAt"]), tz=dt_timezone.utc),
            "voting_ends_at": datetime.fromtimestamp(int(args["votingEndsAt"]), tz=dt_timezone.utc),
            "opened_tx": event.tx_hash,
        },
    )
    # Escrow state is driven by the Vault's own events (DisputeRaised /
    # DisputeResolved) — do not touch it here or a replay could revert a
    # resolved escrow back to Disputed.
    return {"dispute_id": dispute.on_chain_id}


def _add_panel_members(dispute, members, offset: int) -> None:
    from apps.governance.models import DisputeMember

    zero = "0x" + "0" * 40
    for position, resolver in enumerate(members):
        if not resolver or resolver.lower() == zero:
            continue
        DisputeMember.objects.get_or_create(
            dispute=dispute,
            participant=_participant_for(resolver),
            defaults={"position": offset + position},
        )


def _handle_panel_selected(event) -> dict:
    from apps.governance.models import Dispute

    args = event.args
    dispute = Dispute.objects.filter(on_chain_id=int(args["disputeId"])).first()
    if dispute:
        dispute.panel_selected = True
        dispute.save(update_fields=["panel_selected", "updated_at"])
        _add_panel_members(dispute, args["members"], 0)
    return {"dispute_id": args["disputeId"]}


def _handle_dispute_decision_recorded(event) -> dict:
    from datetime import datetime, timezone as dt_timezone

    from apps.governance.models import Dispute

    args = event.args
    dispute = Dispute.objects.filter(on_chain_id=int(args["disputeId"])).first()
    if dispute:
        dispute.state = Dispute.State.RESOLVED
        dispute.release_to_seller = bool(args["releaseToSeller"])
        dispute.appeal_ends_at = datetime.fromtimestamp(int(args["finalizeAfter"]), tz=dt_timezone.utc)
        dispute.decision_tx = event.tx_hash
        dispute.save(
            update_fields=["state", "release_to_seller", "appeal_ends_at", "decision_tx", "updated_at"]
        )
    return {"dispute_id": args["disputeId"]}


def _handle_appeal_opened(event) -> dict:
    from datetime import datetime, timezone as dt_timezone

    from apps.governance.models import Dispute

    args = event.args
    dispute = Dispute.objects.filter(on_chain_id=int(args["disputeId"])).first()
    if dispute:
        dispute.state = Dispute.State.APPEALED
        dispute.appeal_bond_wei = int(args["bond"])
        dispute.appeal_voting_ends_at = datetime.fromtimestamp(
            int(args["votingEndsAt"]), tz=dt_timezone.utc
        )
        dispute.save(
            update_fields=[
                "state",
                "appeal_bond_wei",
                "appeal_voting_ends_at",
                "updated_at",
            ]
        )
    return {"dispute_id": args["disputeId"]}


def _handle_appeal_panel_selected(event) -> dict:
    from apps.governance.models import Dispute

    args = event.args
    dispute = Dispute.objects.filter(on_chain_id=int(args["disputeId"])).first()
    if dispute:
        _add_panel_members(dispute, args["members"], 10)
    return {"dispute_id": args["disputeId"]}


def _handle_appeal_voted(event) -> dict:
    from apps.governance.models import Dispute, DisputeMember

    args = event.args
    dispute = Dispute.objects.filter(on_chain_id=int(args["disputeId"])).first()
    if dispute:
        member = DisputeMember.objects.filter(
            dispute=dispute,
            participant__evm_address__iexact=args["resolver"].lower(),
            position__gte=10,
        ).first()
        if member:
            member.vote_release = bool(args["releaseToSeller"])
            member.save(update_fields=["vote_release"])
        # Recount for replay safety.
        dispute.appeal_votes_for_release = dispute.members.filter(
            position__gte=10, vote_release=True
        ).count()
        dispute.appeal_votes_for_refund = dispute.members.filter(
            position__gte=10, vote_release=False
        ).count()
        dispute.save(
            update_fields=[
                "appeal_votes_for_release",
                "appeal_votes_for_refund",
                "updated_at",
            ]
        )
    return {"dispute_id": args["disputeId"]}


def _handle_appeal_resolved(event) -> dict:
    from apps.governance.models import Dispute

    args = event.args
    dispute = Dispute.objects.filter(on_chain_id=int(args["disputeId"])).first()
    if dispute:
        dispute.release_to_seller = bool(args["releaseToSeller"])
        dispute.save(update_fields=["release_to_seller", "updated_at"])
    return {"dispute_id": args["disputeId"]}


def _handle_resolver_voted(event) -> dict:
    from apps.governance.models import Dispute, DisputeMember

    args = event.args
    dispute = Dispute.objects.filter(on_chain_id=int(args["disputeId"])).first()
    if dispute:
        member = DisputeMember.objects.filter(
            dispute=dispute,
            participant__evm_address__iexact=args["resolver"].lower(),
            position__lt=10,
        ).first()
        if member:
            member.vote_release = bool(args["releaseToSeller"])
            member.save(update_fields=["vote_release"])
        # Recount instead of incrementing — handlers must be replay-safe.
        first_panel = dispute.members.filter(position__lt=10)
        dispute.votes_for_release = first_panel.filter(vote_release=True).count()
        dispute.votes_for_refund = first_panel.filter(vote_release=False).count()
        dispute.save(update_fields=["votes_for_release", "votes_for_refund", "updated_at"])
    return {"dispute_id": args["disputeId"]}


def _handle_dispute_settled(event) -> dict:
    from apps.governance.models import Dispute

    args = event.args
    dispute = Dispute.objects.filter(on_chain_id=int(args["disputeId"])).first()
    if dispute:
        dispute.state = Dispute.State.FINAL
        dispute.release_to_seller = bool(args["releaseToSeller"])
        dispute.settled_tx = event.tx_hash
        dispute.save(update_fields=["state", "release_to_seller", "settled_tx", "updated_at"])
    return {"dispute_id": args["disputeId"]}


def _handle_reward_claimed(event) -> dict:
    from django.db.models import Sum

    from apps.governance.models import Dispute, DisputeMember, ResolverProfile

    args = event.args
    dispute = Dispute.objects.filter(on_chain_id=int(args["disputeId"])).first()
    if dispute:
        member = DisputeMember.objects.filter(
            dispute=dispute, participant__evm_address__iexact=args["resolver"].lower()
        ).first()
        if member:
            member.claimed = True
            member.claimed_uqor = _wei_to_uqor(args["amount"])
            member.save(update_fields=["claimed", "claimed_uqor"])

        profile, _ = ResolverProfile.objects.get_or_create(participant=_participant_for(args["resolver"]))
        # Recompute from member claims — replay-safe.
        total = (
            DisputeMember.objects.filter(participant=profile.participant, claimed=True).aggregate(
                total=Sum("claimed_uqor")
            )["total"]
            or 0
        )
        profile.rewards_claimed_uqor = total
        profile.save(update_fields=["rewards_claimed_uqor", "updated_at"])
    return {"dispute_id": args["disputeId"]}


# ---------------------------------------------------------------------------
# Governance proposals
# ---------------------------------------------------------------------------

_ADD_VERIFIER_SELECTOR = "0x7065cb48"  # addVerifier(address)
_REMOVE_VERIFIER_SELECTOR = "0xfcec1d9b"  # removeVerifier(address)


def _proposal_kind(call_data: str) -> str:
    from apps.governance.models import Proposal

    if call_data.startswith(_ADD_VERIFIER_SELECTOR):
        return Proposal.Kind.VERIFIER_APPROVAL
    if call_data.startswith(_REMOVE_VERIFIER_SELECTOR):
        return Proposal.Kind.VERIFIER_REMOVAL
    return Proposal.Kind.OTHER


def _handle_proposal_created(event, *, has_target: bool) -> dict:
    from datetime import datetime, timezone as dt_timezone

    from apps.governance.models import Proposal

    args = event.args
    proposal_id = int(args["proposalId"])

    call_data = args.get("callData", "") if has_target else ""
    call_data_hex = "0x" + bytes(call_data).hex() if isinstance(call_data, (bytes, bytearray)) else str(call_data)

    proposal, _ = Proposal.objects.update_or_create(
        on_chain_id=proposal_id,
        defaults={
            "proposer": _participant_for(args["proposer"]),
            "kind": _proposal_kind(call_data_hex) if call_data_hex.startswith("0x") and len(call_data_hex) > 2 else Proposal.Kind.OTHER,
            "title": args.get("title", f"Proposal #{proposal_id}"),
            "description": "",
            "voting_ends_at": datetime.fromtimestamp(int(args["votingEndsAt"]), tz=dt_timezone.utc),
            "payload": {
                "target": args.get("target", ""),
                "call_data": call_data_hex,
                "description_hash": "",
            },
            "state": Proposal.State.OPEN,
        },
    )
    return {"proposal_id": proposal.on_chain_id}


def _handle_proposal_voted(event) -> dict:
    from apps.governance.models import Proposal, Vote

    args = event.args
    proposal = Proposal.objects.filter(on_chain_id=int(args["proposalId"])).first()
    if proposal and "voter" in args:
        choice = {1: Vote.Choice.FOR, 2: Vote.Choice.AGAINST, 3: Vote.Choice.ABSTAIN}.get(
            int(args["choice"]), Vote.Choice.ABSTAIN
        )
        Vote.objects.get_or_create(
            proposal=proposal,
            voter=_participant_for(args["voter"]),
            defaults={"choice": choice},
        )
    return {"proposal_id": args["proposalId"]}


def _handle_proposal_executed(event) -> dict:
    from apps.governance.models import Proposal

    proposal = Proposal.objects.filter(on_chain_id=int(event.args["proposalId"])).first()
    if proposal:
        proposal.state = Proposal.State.EXECUTED
        proposal.execution_tx = event.tx_hash
        proposal.save(update_fields=["state", "execution_tx"])
    return {"proposal_id": event.args["proposalId"]}


def _handle_proposal_rejected(event) -> dict:
    from apps.governance.models import Proposal

    proposal = Proposal.objects.filter(on_chain_id=int(event.args["proposalId"])).first()
    if proposal:
        proposal.state = Proposal.State.REJECTED
        proposal.save(update_fields=["state"])
    return {"proposal_id": event.args["proposalId"]}


def _handle_proposal_terminal(state):
    """Build a replay-safe handler that marks a proposal in a terminal state."""

    def _handle(event) -> dict:
        from apps.governance.models import Proposal

        proposal = Proposal.objects.filter(on_chain_id=int(event.args["proposalId"])).first()
        if proposal:
            proposal.state = state
            proposal.save(update_fields=["state"])
        return {"proposal_id": event.args["proposalId"]}

    return _handle


def _handle_carrier_attested(event) -> dict:
    args = event.args
    escrow = Escrow.objects.filter(on_chain_id=int(args["escrowId"])).first()
    if escrow:
        escrow.carrier_attested = True
        escrow.carrier_payload_hash = "0x" + bytes(args["payloadHash"]).hex()
        escrow.save(update_fields=["carrier_attested", "carrier_payload_hash", "updated_at"])
        # Also count as fulfilment evidence (same reputation hook as oracle)
        ReputationEvent.objects.get_or_create(
            escrow=escrow,
            participant=escrow.seller,
            kind=ReputationEvent.Kind.FULFILMENT_VERIFIED,
            defaults={"on_chain_tx": event.tx_hash, "note": "carrier attestation"},
        )
        _recompute(escrow.seller)
    return {"escrow_id": args["escrowId"]}

def _handle_carrier_registered(event) -> dict:
    return {"carrier": event.args.get("carrier")}

def _handle_carrier_removed(event) -> dict:
    return {"carrier": event.args.get("carrier")}

def _handle_logistics_paid(event) -> dict:
    return {"escrow_id": event.args.get("escrowId")}

def _handle_credits_noop(event) -> dict:
    # Credits are read live from the Vault (relayer.vault_credits) and never
    # projected: recording them here would duplicate on-chain state in the DB.
    # The handler exists so every fetched event has an explicit disposition
    # instead of silently falling through.
    return {"account": event.args.get("account"), "amount": event.args.get("amount")}


def _handle_registry_noop(event) -> dict:
    # Verifier membership is read live from the registry
    # (relayer.is_verifier / Vault._isVerifier); the board's Slashed event
    # is likewise informational — the resulting stake change arrives as a
    # StakeWithdrawn (or is settled in DisputeSettled). Record-only.
    return {"account": event.args.get("account") or event.args.get("verifier")}

HANDLERS = {
    ("SweeftMarketplace", "ListingCreated"): _handle_listing_created,
    ("SweeftMarketplace", "ListingPurchased"): _handle_listing_purchased,
    ("SweeftMarketplace", "ListingCancelled"): _handle_listing_cancelled,
    ("SweeftVault", "EscrowCreated"): _handle_escrow_created,
    ("SweeftVault", "CarrierAttested"): _handle_carrier_attested,
    ("SweeftVault", "CarrierRegistered"): _handle_carrier_registered,
    ("SweeftVault", "CarrierRemoved"): _handle_carrier_removed,
    ("SweeftVault", "LogisticsPaid"): _handle_logistics_paid,
    ("SweeftVault", "EscrowFunded"): _handle_escrow_funded,
    ("SweeftVault", "MarkedDelivered"): _handle_marked_delivered,
    ("SweeftVault", "ReceiptConfirmed"): _handle_receipt_confirmed,
    ("SweeftVault", "EvidenceAttested"): _handle_evidence_attested,
    ("SweeftVault", "FundsReleased"): _handle_funds_released,
    ("SweeftVault", "EscrowRefunded"): _handle_escrow_refunded,
    ("SweeftVault", "DisputeRaised"): _handle_vault_dispute_raised,
    ("SweeftVault", "DisputeResolved"): _handle_dispute_resolved,
    ("SweeftVault", "FeeCollected"): _handle_fee_collected,
    ("SweeftVault", "CreditsAccrued"): _handle_credits_noop,
    ("SweeftVault", "CreditsWithdrawn"): _handle_credits_noop,
    ("SweeftDisputeBoard", "Staked"): _handle_staked,
    ("SweeftDisputeBoard", "StakeWithdrawn"): _handle_stake_withdrawn,
    ("SweeftDisputeBoard", "DisputeOpened"): _handle_dispute_opened,
    ("SweeftDisputeBoard", "PanelSelected"): _handle_panel_selected,
    ("SweeftDisputeBoard", "ResolverVoted"): _handle_resolver_voted,
    ("SweeftDisputeBoard", "DisputeDecisionRecorded"): _handle_dispute_decision_recorded,
    ("SweeftDisputeBoard", "AppealOpened"): _handle_appeal_opened,
    ("SweeftDisputeBoard", "AppealPanelSelected"): _handle_appeal_panel_selected,
    ("SweeftDisputeBoard", "AppealResolverVoted"): _handle_appeal_voted,
    ("SweeftDisputeBoard", "AppealResolved"): _handle_appeal_resolved,
    ("SweeftDisputeBoard", "DisputeSettled"): _handle_dispute_settled,
    ("SweeftDisputeBoard", "RewardClaimed"): _handle_reward_claimed,
    ("SweeftDisputeBoard", "Slashed"): _handle_registry_noop,
    ("SweeftOracleRegistry", "VerifierAdded"): _handle_registry_noop,
    ("SweeftOracleRegistry", "VerifierRemoved"): _handle_registry_noop,
    ("SweeftDAO", "ProposalCreated"): lambda e: _handle_proposal_created(e, has_target=False),
    ("SweeftDAO", "VoteCast"): _handle_proposal_voted,
    ("SweeftDAO", "ProposalExecuted"): _handle_proposal_executed,
    ("SweeftDAO", "ProposalRejected"): _handle_proposal_rejected,
    ("SweeftDAO2", "ProposalCreated"): lambda e: _handle_proposal_created(e, has_target=True),
    ("SweeftDAO2", "VoteCast"): _handle_proposal_voted,
    ("SweeftDAO2", "ProposalExecuted"): _handle_proposal_executed,
    ("SweeftDAO2", "ProposalRejected"): _handle_proposal_rejected,
    ("SweeftDAO2", "ProposalCancelled"): _handle_proposal_terminal("cancelled"),
    ("SweeftDAO2", "ProposalExpired"): _handle_proposal_terminal("expired"),
    ("SweeftDAO2", "ProposalFailed"): _handle_proposal_terminal("failed"),
    ("SweeftDAO2", "ProposalVetoed"): _handle_proposal_terminal("vetoed"),
}
