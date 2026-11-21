"""Event indexer — the chain is the source of truth; PostgreSQL is a cache.

Reads contract events in chunks (public RPC caps eth_getLogs at 10k blocks),
records each log exactly once (unique tx_hash + log_index), and projects the
state into Django models.
"""

from __future__ import annotations

import hashlib
import json
import logging
from datetime import datetime, timezone as dt_timezone

from django.db import transaction

from apps.blockchain.models import IndexerCursor, ProcessedEvent
from apps.commerce.models import Order
from apps.escrow.models import Escrow
from apps.marketplace.models import Listing
from apps.participants.models import Participant
from apps.reputation.models import ReputationEvent, ReputationProfile
from integrations.qorechain.client import get_evm_client
from integrations.qorechain.contracts import artifact_path, contract_address
from integrations.qorechain.contracts_base import load_abi, make_contract
from integrations.qorechain.events import fetch_events

logger = logging.getLogger(__name__)

CONTRACTS = ["SweeftMarketplace", "SweeftVault", "SweeftOracleRegistry", "SweeftDAO", "SweeftDAO2", "SweeftDisputeBoard"]

# Blocks to stay behind the tip when indexing (public RPC replica lag).
HEAD_LAG_BLOCKS = 8

EVENTS = {
    "SweeftMarketplace": ["ListingCreated", "ListingPurchased", "ListingCancelled"],
    "SweeftVault": [
        "EscrowCreated",
        "EscrowFunded",
        "MarkedDelivered",
        "ReceiptConfirmed",
        "EvidenceAttested",
        "FundsReleased",
        "EscrowRefunded",
        "DisputeRaised",
        "DisputeResolved",
        "FeeCollected",
    ],
    "SweeftOracleRegistry": ["VerifierAdded", "VerifierRemoved"],
    "SweeftDAO": ["ProposalCreated", "VoteCast", "ProposalExecuted", "ProposalRejected"],
    "SweeftDAO2": ["ProposalCreated", "VoteCast", "ProposalExecuted", "ProposalRejected"],
    "SweeftDisputeBoard": [
        "Staked",
        "StakeWithdrawn",
        "DisputeOpened",
        "ResolverJoined",
        "ResolverVoted",
        "DisputeSettled",
        "RewardClaimed",
    ],
}


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
    try:
        listing_contract = _contract("SweeftMarketplace")
        if listing_contract is not None:
            on_chain = listing_contract.functions.getListing(int(args["listingId"])).call()
            metadata = _fetch_verified_metadata(on_chain[4], metadata_hash)
    except Exception:
        logger.exception("could not load listing metadata")

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
        escrow.pqc_nonce = int(args["pqcNonce"]) + 1
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
        escrow.pqc_nonce = int(args["pqcNonce"]) + 1
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
            "voting_ends_at": datetime.fromtimestamp(int(args["votingEndsAt"]), tz=dt_timezone.utc),
            "opened_tx": event.tx_hash,
        },
    )
    # Escrow state is driven by the Vault's own events (DisputeRaised /
    # DisputeResolved) — do not touch it here or a replay could revert a
    # resolved escrow back to Disputed.
    return {"dispute_id": dispute.on_chain_id}


def _handle_resolver_joined(event) -> dict:
    from apps.governance.models import Dispute, DisputeMember

    args = event.args
    dispute = Dispute.objects.filter(on_chain_id=int(args["disputeId"])).first()
    if dispute:
        DisputeMember.objects.get_or_create(
            dispute=dispute,
            participant=_participant_for(args["resolver"]),
            defaults={"position": int(args["position"])},
        )
    return {"dispute_id": args["disputeId"]}


def _handle_resolver_voted(event) -> dict:
    from apps.governance.models import Dispute, DisputeMember

    args = event.args
    dispute = Dispute.objects.filter(on_chain_id=int(args["disputeId"])).first()
    if dispute:
        member = DisputeMember.objects.filter(
            dispute=dispute, participant__evm_address__iexact=args["resolver"].lower()
        ).first()
        if member:
            member.vote_release = bool(args["releaseToSeller"])
            member.save(update_fields=["vote_release"])
        # Recount instead of incrementing — handlers must be replay-safe.
        dispute.votes_for_release = dispute.members.filter(vote_release=True).count()
        dispute.votes_for_refund = dispute.members.filter(vote_release=False).count()
        dispute.save(update_fields=["votes_for_release", "votes_for_refund", "updated_at"])
    return {"dispute_id": args["disputeId"]}


def _handle_dispute_settled(event) -> dict:
    from apps.governance.models import Dispute

    args = event.args
    dispute = Dispute.objects.filter(on_chain_id=int(args["disputeId"])).first()
    if dispute:
        dispute.state = Dispute.State.RESOLVED
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


HANDLERS = {
    ("SweeftMarketplace", "ListingCreated"): _handle_listing_created,
    ("SweeftMarketplace", "ListingPurchased"): _handle_listing_purchased,
    ("SweeftMarketplace", "ListingCancelled"): _handle_listing_cancelled,
    ("SweeftVault", "EscrowCreated"): _handle_escrow_created,
    ("SweeftVault", "EscrowFunded"): _handle_escrow_funded,
    ("SweeftVault", "MarkedDelivered"): _handle_marked_delivered,
    ("SweeftVault", "ReceiptConfirmed"): _handle_receipt_confirmed,
    ("SweeftVault", "EvidenceAttested"): _handle_evidence_attested,
    ("SweeftVault", "FundsReleased"): _handle_funds_released,
    ("SweeftVault", "EscrowRefunded"): _handle_escrow_refunded,
    ("SweeftVault", "DisputeRaised"): _handle_vault_dispute_raised,
    ("SweeftVault", "DisputeResolved"): _handle_dispute_resolved,
    ("SweeftVault", "FeeCollected"): _handle_fee_collected,
    ("SweeftDisputeBoard", "Staked"): _handle_staked,
    ("SweeftDisputeBoard", "StakeWithdrawn"): _handle_stake_withdrawn,
    ("SweeftDisputeBoard", "DisputeOpened"): _handle_dispute_opened,
    ("SweeftDisputeBoard", "ResolverJoined"): _handle_resolver_joined,
    ("SweeftDisputeBoard", "ResolverVoted"): _handle_resolver_voted,
    ("SweeftDisputeBoard", "DisputeSettled"): _handle_dispute_settled,
    ("SweeftDisputeBoard", "RewardClaimed"): _handle_reward_claimed,
    ("SweeftDAO", "ProposalCreated"): lambda e: _handle_proposal_created(e, has_target=False),
    ("SweeftDAO", "VoteCast"): _handle_proposal_voted,
    ("SweeftDAO", "ProposalExecuted"): _handle_proposal_executed,
    ("SweeftDAO", "ProposalRejected"): _handle_proposal_rejected,
    ("SweeftDAO2", "ProposalCreated"): lambda e: _handle_proposal_created(e, has_target=True),
    ("SweeftDAO2", "VoteCast"): _handle_proposal_voted,
    ("SweeftDAO2", "ProposalExecuted"): _handle_proposal_executed,
    ("SweeftDAO2", "ProposalRejected"): _handle_proposal_rejected,
}


# ---------------------------------------------------------------------------
# Cursor-driven sync
# ---------------------------------------------------------------------------


def sync_contract(name: str, *, max_blocks: int | None = None) -> int:
    """Process new events for one contract. Returns the number of events handled."""
    contract = _contract(name)
    if contract is None:
        logger.warning("contract %s not deployed — skipping", name)
        return 0

    w3 = get_evm_client()
    latest = w3.eth.block_number
    # Index only up to a few blocks behind the tip: public RPC replicas can
    # lag slightly, and a receipt's block may not yet be visible to a lagging
    # replica's eth_blockNumber — indexing to the tip would skip events.
    latest = max(0, latest - HEAD_LAG_BLOCKS)
    cursor, _ = IndexerCursor.objects.get_or_create(
        contract_name=name, defaults={"contract_address": contract.address, "last_processed_block": 0}
    )
    if cursor.contract_address != contract.address:
        # Contract redeployed: start from its deployment block.
        cursor.contract_address = contract.address
        cursor.last_processed_block = max(0, latest - 50_000)
        cursor.save(update_fields=["contract_address", "last_processed_block", "updated_at"])

    if cursor.last_processed_block == 0:
        cursor.last_processed_block = max(0, latest - 50_000)

    start = cursor.last_processed_block + 1
    if start > latest:
        return 0
    if max_blocks:
        latest = min(latest, start + max_blocks - 1)

    handled = 0
    first_failed_block: int | None = None
    for event_name in EVENTS.get(name, []):
        for event in fetch_events(contract, event_name, start, latest):
            handler = HANDLERS.get((name, event_name))
            try:
                # The processed-event record and the projection commit together:
                # a handler failure rolls back the record so the event is retried.
                with transaction.atomic():
                    _, created = ProcessedEvent.objects.get_or_create(
                        tx_hash=event.tx_hash,
                        log_index=event.log_index,
                        defaults={
                            "contract_name": name,
                            "event_name": event_name,
                            "block_number": event.block_number,
                            "payload": {k: str(v) for k, v in event.args.items()},
                        },
                    )
                    if not created:
                        continue
                    if handler:
                        handler(event)
                handled += 1
            except Exception:
                logger.exception("handler failed for %s.%s (%s)", name, event_name, event.key)
                if first_failed_block is None or event.block_number < first_failed_block:
                    first_failed_block = event.block_number

    # Never advance past a block whose event failed to project — retry next run.
    cursor.last_processed_block = (
        first_failed_block - 1 if first_failed_block is not None else latest
    )
    cursor.save(update_fields=["last_processed_block", "updated_at"])
    return handled


def sync_all(*, max_blocks: int | None = None, max_rounds: int = 15) -> dict:
    """Catch up every contract, looping until no cursor advances further.

    A single pass caps at ``max_blocks`` per contract (the public RPC limits
    eth_getLogs); the loop lets one call catch up across the full history.
    """
    results = {name: 0 for name in CONTRACTS}
    for _ in range(max_rounds):
        before = {c.contract_name: c.last_processed_block for c in IndexerCursor.objects.all()}
        for name in CONTRACTS:
            results[name] += sync_contract(name, max_blocks=max_blocks)
        after = {c.contract_name: c.last_processed_block for c in IndexerCursor.objects.all()}
        if after == before:
            break
    return results
