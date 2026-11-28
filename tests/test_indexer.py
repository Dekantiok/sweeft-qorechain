"""Indexer structure tests: projections split + legacy DAO exclusion.

Run with: python manage.py test tests.test_indexer
"""

from __future__ import annotations

from unittest import mock

from django.test import SimpleTestCase, TestCase

from apps.blockchain.services import indexer, projections


class IndexerRegistryTests(SimpleTestCase):
    def test_default_sync_excludes_legacy_dao(self):
        self.assertNotIn("SweeftDAO", indexer.CONTRACTS)
        self.assertEqual(indexer.LEGACY_CONTRACTS, ["SweeftDAO"])
        self.assertIn("SweeftDAO2", indexer.CONTRACTS)
        self.assertIn("SweeftDAO", indexer.EVENTS)  # explicit backfill still possible

    def test_handlers_cover_every_indexed_event(self):
        for contract, events in indexer.EVENTS.items():
            for event in events:
                self.assertIn(
                    (contract, event),
                    projections.HANDLERS,
                    f"missing handler for {contract}.{event}",
                )

    def test_indexer_re_exports_projection_helpers(self):
        # Back-compat for seed_from_chain / escrow views importing from indexer.
        self.assertIs(indexer.HANDLERS, projections.HANDLERS)
        self.assertIs(indexer._contract, projections._contract)
        self.assertIs(indexer._participant_for, projections._participant_for)
        self.assertIs(indexer._catalog_entry, projections._catalog_entry)

    def test_wei_to_uqor_conversion(self):
        self.assertEqual(projections._wei_to_uqor(10**18), 1_000_000)
        self.assertEqual(projections._wei_to_uqor(1), 0)


class SyncAllResilienceTests(TestCase):
    def test_rpc_failure_in_one_contract_does_not_abort_sync(self):
        # Regression from the Render log: a 429 on eth_blockNumber inside
        # one contract used to crash seed_from_chain and loop the deploy.
        def flaky(name, *, max_blocks=None):
            if name == "SweeftVault":
                raise RuntimeError("429 Too Many Requests")
            return 2

        with mock.patch.object(indexer, "sync_contract", side_effect=flaky):
            results = indexer.sync_all(max_rounds=1)
        self.assertEqual(results["SweeftVault"], 0)
        self.assertEqual(results["SweeftMarketplace"], 2)
