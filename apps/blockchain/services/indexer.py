"""Event indexer - the chain is the source of truth; PostgreSQL is a cache.

Reads contract events in chunks (public RPC caps eth_getLogs at 10k blocks),
records each log exactly once (unique tx_hash + log_index), and projects the
state into Django models via :mod:`apps.blockchain.services.projections`.

This module owns fetching/cursor state only; event->row handlers live in
``projections``. Names re-exported here (``_contract``, ``_participant_for``,
``_catalog_entry``, ``HANDLERS``) are kept for existing callers
(``seed_from_chain``, escrow views).
"""

from __future__ import annotations

import logging

from django.db import transaction

from apps.blockchain.models import IndexerCursor, ProcessedEvent
from apps.blockchain.services.projections import (  # noqa: F401  (re-exported)
    HANDLERS,
    _catalog_entry,
    _contract,
    _participant_for,
    _wei_to_uqor,
)
from integrations.qorechain.client import get_evm_client
from integrations.qorechain.events import fetch_events

logger = logging.getLogger(__name__)


# Active stack (v8). SweeftDAO is superseded by DAO2 and only indexed on
# explicit request (include_legacy=True) for historical backfill.
ACTIVE_CONTRACTS = ["SweeftMarketplace", "SweeftVault", "SweeftOracleRegistry", "SweeftDAO2", "SweeftDisputeBoard"]
LEGACY_CONTRACTS = ["SweeftDAO"]
CONTRACTS = ACTIVE_CONTRACTS  # default sync set (back-compat alias)

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
        "CarrierAttested",
        "CarrierRegistered",
        "CarrierRemoved",
        "LogisticsPaid",
        "CreditsAccrued",
        "CreditsWithdrawn",
    ],
    "SweeftOracleRegistry": ["VerifierAdded", "VerifierRemoved"],
    "SweeftDAO": ["ProposalCreated", "VoteCast", "ProposalExecuted", "ProposalRejected"],
    "SweeftDAO2": [
        "ProposalCreated",
        "VoteCast",
        "ProposalExecuted",
        "ProposalRejected",
        "ProposalCancelled",
        "ProposalExpired",
        "ProposalFailed",
        "ProposalVetoed",
    ],
    "SweeftDisputeBoard": [
        "Staked",
        "StakeWithdrawn",
        "DisputeOpened",
        "PanelSelected",
        "ResolverVoted",
        "DisputeDecisionRecorded",
        "SeedCheckpointed",
        "AppealOpened",
        "AppealPanelSelected",
        "AppealResolverVoted",
        "AppealResolved",
        "DisputeSettled",
        "RewardClaimed",
        "Slashed",
    ],
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


def sync_all(*, max_blocks: int | None = None, max_rounds: int = 15, include_legacy: bool = False) -> dict:
    """Catch up every contract, looping until no cursor advances further.

    A single pass caps at ``max_blocks`` per contract (the public RPC limits
    eth_getLogs); the loop lets one call catch up across the full history.
    """
    names = list(CONTRACTS) + (list(LEGACY_CONTRACTS) if include_legacy else [])
    results = {name: 0 for name in names}
    for _ in range(max_rounds):
        before = {c.contract_name: c.last_processed_block for c in IndexerCursor.objects.all()}
        for name in names:
            results[name] += sync_contract(name, max_blocks=max_blocks)
        after = {c.contract_name: c.last_processed_block for c in IndexerCursor.objects.all()}
        if after == before:
            break
    return results
