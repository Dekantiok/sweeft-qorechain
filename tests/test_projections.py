"""Projection replay/idempotency tests + indexer cursor failure semantics.

Handlers must be replay-safe: the indexer records a ProcessedEvent and the
projection in one transaction and retries on failure, so invoking a handler
twice must not double-count (reputation, votes) or duplicate rows.

Run with: python manage.py test tests.test_projections
"""

from __future__ import annotations

import time
from types import SimpleNamespace
from unittest import mock

from django.test import TestCase
from django.utils import timezone

from apps.blockchain.models import IndexerCursor, ProcessedEvent
from apps.blockchain.services import indexer, projections
from apps.commerce.models import Order
from apps.escrow.models import Escrow
from apps.governance.models import Dispute, DisputeMember
from apps.participants.models import Participant
from apps.reputation.models import ReputationEvent


def _event(args, *, tx="0xtx", block=100, log_index=0):
    return SimpleNamespace(
        args=args, tx_hash=tx, block_number=block, log_index=log_index,
        key=f"{tx}:{log_index}",
    )


class ProjectionReplayTests(TestCase):
    def setUp(self):
        self.buyer = Participant.objects.create(
            display_name="Buyer", evm_address="0x1111111111111111111111111111111111111111",
            qor_address="qor1buyer",
        )
        self.seller = Participant.objects.create(
            display_name="Seller", evm_address="0x2222222222222222222222222222222222222222",
            qor_address="qor1seller",
        )
        self.order = Order.objects.create(
            reference="SW-000001", buyer=self.buyer, seller=self.seller,
            unit_price_uqor=1000, total_uqor=1000, state=Order.State.FUNDED,
        )
        self.escrow = Escrow.objects.create(
            on_chain_id=1, order=self.order, buyer=self.buyer, seller=self.seller,
            amount_uqor=1000, delivery_deadline=timezone.now(),
            state=Escrow.State.FUNDED,
        )

    def test_funds_released_replay_does_not_double_count(self):
        ev = _event({"escrowId": 1, "seller": self.seller.evm_address, "amount": 10**15, "nonce": 0})
        projections._handle_funds_released(ev)
        projections._handle_funds_released(ev)  # replay
        self.assertEqual(
            ReputationEvent.objects.filter(kind=ReputationEvent.Kind.ESCROW_COMPLETED).count(), 2
        )  # one per participant, not per invocation
        profile = self.seller.reputation
        self.assertEqual(profile.successful_transactions, 1)
        self.escrow.refresh_from_db()
        self.assertEqual(self.escrow.state, Escrow.State.COMPLETED)
        self.assertEqual(self.escrow.pqc_nonce, 1)

    def test_evidence_attested_replay_single_event(self):
        ev = _event({"escrowId": 1, "verifier": "0x3333333333333333333333333333333333333333"})
        projections._handle_evidence_attested(ev)
        projections._handle_evidence_attested(ev)
        self.assertEqual(
            ReputationEvent.objects.filter(
                kind=ReputationEvent.Kind.FULFILMENT_VERIFIED
            ).count(),
            1,
        )

    def test_escrow_created_replay_single_row(self):
        args = {
            "escrowId": 7, "buyer": self.buyer.evm_address,
            "seller": self.seller.evm_address, "amount": 10**15,
            "deliveryDeadline": int(time.time()) + 86400,
        }
        projections._handle_escrow_created(_event(args))
        projections._handle_escrow_created(_event(args, tx="0xtx2"))
        self.assertEqual(Escrow.objects.filter(on_chain_id=7).count(), 1)
        self.assertEqual(Order.objects.filter(reference="SW-000007").count(), 1)

    def test_resolver_voted_recount_is_replay_safe(self):
        resolver = Participant.objects.create(
            display_name="Resolver", evm_address="0x3333333333333333333333333333333333333333"
        )
        dispute = Dispute.objects.create(on_chain_id=3, escrow=self.escrow, raiser=self.buyer)
        DisputeMember.objects.create(dispute=dispute, participant=resolver, position=0)
        ev = _event({"disputeId": 3, "resolver": resolver.evm_address, "releaseToSeller": True})
        projections._handle_resolver_voted(ev)
        projections._handle_resolver_voted(ev)  # replay must not increment twice
        dispute.refresh_from_db()
        self.assertEqual(dispute.votes_for_release, 1)
        self.assertEqual(dispute.votes_for_refund, 0)

    def test_noop_handlers_record_without_projection(self):
        ev = _event({"account": self.buyer.evm_address, "amount": 5})
        self.assertEqual(projections._handle_credits_noop(ev)["account"], self.buyer.evm_address)
        self.assertEqual(Escrow.objects.count(), 1)  # nothing wrote


class CursorFailureTests(TestCase):
    """sync_contract must never advance past a failed event's block."""

    def _run_sync(self, events, fail=False):
        fake_contract = mock.MagicMock()
        fake_contract.address = "0x0000000000000000000000000000000000000aa"
        fake_w3 = mock.MagicMock()
        fake_w3.eth.block_number = 1000
        cursor = IndexerCursor.objects.create(contract_name="SweeftVault", last_processed_block=990)
        handler = mock.MagicMock(side_effect=RuntimeError("boom")) if fail else mock.MagicMock()

        def _fetch(contract, event_name, start, latest):
            return iter(events) if event_name == "EscrowFunded" else iter([])

        with mock.patch.object(indexer, "_contract", return_value=fake_contract), \
             mock.patch.object(indexer, "get_evm_client", return_value=fake_w3), \
             mock.patch.object(indexer, "fetch_events", side_effect=_fetch), \
             mock.patch.dict(indexer.HANDLERS, {("SweeftVault", "EscrowFunded"): handler}):
            handled = indexer.sync_contract("SweeftVault")
        cursor.refresh_from_db()
        return handled, cursor.last_processed_block

    def test_cursor_advances_to_head_on_success(self):
        ev = _event({"escrowId": 1}, block=995)
        handled, cursor_block = self._run_sync([ev])
        self.assertEqual(handled, 1)
        # head lag: 1000 - 8
        self.assertEqual(cursor_block, 992)
        self.assertEqual(ProcessedEvent.objects.count(), 1)

    def test_cursor_stops_before_failed_block(self):
        ev = _event({"escrowId": 1}, block=995)
        handled, cursor_block = self._run_sync([ev], fail=True)
        self.assertEqual(handled, 0)
        self.assertEqual(cursor_block, 994)  # failed_block - 1
        # Failed projection must roll back its ProcessedEvent so it is retried.
        self.assertEqual(ProcessedEvent.objects.count(), 0)
