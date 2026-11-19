"""Event indexer — the chain is the source of truth; PostgreSQL is a cache.

Reads contract events in chunks (public RPC caps eth_getLogs at 10k blocks),
records each log exactly once (unique tx_hash + log_index), and projects the
state into Django models.
"""

from __future__ import annotations

import hashlib
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

CONTRACTS = ["SweeftMarketplace", "SweeftVault", "SweeftOracleRegistry", "SweeftDAO"]

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
    ],
    "SweeftOracleRegistry": ["VerifierAdded", "VerifierRemoved"],
    "SweeftDAO": ["ProposalCreated", "VoteCast", "ProposalExecuted", "ProposalRejected"],
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


def _handle_listing_created(event) -> dict:
    args = event.args
    listing, created = Listing.objects.update_or_create(
        on_chain_id=int(args["listingId"]),
        defaults={
            "seller": _participant_for(args["seller"]),
            "title": f"Listing #{args['listingId']}",
            "description": "",
            "price_uqor": _wei_to_uqor(args["price"]),
            "quantity": int(args["quantity"]),
            "status": Listing.Status.ACTIVE,
            "metadata_hash": "0x" + bytes(args["metadataHash"]).hex(),
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


def sync_all(*, max_blocks: int | None = None) -> dict:
    return {name: sync_contract(name, max_blocks=max_blocks) for name in CONTRACTS}
