"""Relayer health visibility tests.

Run with: python manage.py test tests.test_relayer_health
"""

from __future__ import annotations

import os
from types import SimpleNamespace
from unittest import mock

from django.core.cache import cache
from django.test import SimpleTestCase

from apps.blockchain.services import reads


class RelayerHealthTests(SimpleTestCase):
    def setUp(self):
        cache.clear()

    def tearDown(self):
        cache.clear()

    def test_unconfigured_relayer_reports_plainly(self):
        with mock.patch.dict(os.environ, {"RELAYER_MNEMONIC": ""}):
            health = reads.relayer_health()
        self.assertFalse(health["configured"])
        self.assertTrue(any("RELAYER_MNEMONIC" in w for w in health["warnings"]))

    def test_low_balance_and_dead_window_warn(self):
        account = SimpleNamespace(evm="0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", cosmos="qor1x")
        fake_w3 = mock.MagicMock()
        fake_w3.eth.get_balance.return_value = 10**16  # 0.01 QOR
        fake_w3.to_checksum_address.return_value = account.evm
        with mock.patch.dict(os.environ, {"RELAYER_MNEMONIC": "abandon abandon"}), \
             mock.patch("integrations.qorechain.window.relayer_account", return_value=account), \
             mock.patch("integrations.qorechain.window.evm_window_status", return_value=None), \
             mock.patch.object(reads, "get_evm_client", return_value=fake_w3):
            health = reads.relayer_health()
        self.assertTrue(health["configured"])
        self.assertAlmostEqual(health["balance_qor"], 0.01)
        self.assertTrue(any("low" in w for w in health["warnings"]))
        self.assertTrue(any("window" in w for w in health["warnings"]))

    def test_healthy_relayer_no_warnings(self):
        account = SimpleNamespace(evm="0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", cosmos="qor1x")
        fake_w3 = mock.MagicMock()
        fake_w3.eth.get_balance.return_value = 10**18
        fake_w3.to_checksum_address.return_value = account.evm
        window = {"live": True, "remaining_txs": 100}
        with mock.patch.dict(os.environ, {"RELAYER_MNEMONIC": "abandon abandon"}), \
             mock.patch("integrations.qorechain.window.relayer_account", return_value=account), \
             mock.patch("integrations.qorechain.window.evm_window_status", return_value=window), \
             mock.patch.object(reads, "get_evm_client", return_value=fake_w3):
            health = reads.relayer_health()
        self.assertEqual(health["warnings"], [])
        self.assertEqual(health["window"]["remaining_txs"], 100)
