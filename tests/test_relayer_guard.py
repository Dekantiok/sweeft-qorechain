"""Relayer key-separation guards.

Run with: python manage.py test tests.test_relayer_guard
"""

from __future__ import annotations

import os
from unittest import mock

from django.test import SimpleTestCase

from integrations.qorechain import window


class RelayerGuardTests(SimpleTestCase):
    def test_relayer_refuses_mainnet(self):
        with mock.patch.dict(os.environ, {"QORECHAIN_NETWORK": "mainnet", "RELAYER_MNEMONIC": "x"}):
            with self.assertRaises(RuntimeError):
                window.relayer_account()

    def test_relayer_requires_its_own_mnemonic(self):
        # The deployer mnemonic (owner keys) must never substitute for the
        # low-privilege relayer account.
        env = {"QORECHAIN_NETWORK": "testnet", "SWEEFT_DEPLOYER_MNEMONIC": "abandon abandon"}
        with mock.patch.dict(os.environ, env, clear=False):
            os.environ.pop("RELAYER_MNEMONIC", None)
            with self.assertRaises(RuntimeError) as ctx:
                window.relayer_account()
        self.assertIn("RELAYER_MNEMONIC", str(ctx.exception))

    def test_demo_carrier_testnet_only(self):
        from apps.logistics import carriers

        with mock.patch.dict(os.environ, {"QORECHAIN_NETWORK": "mainnet"}):
            with self.assertRaises(ValueError):
                carriers.demo_carrier_keypair()
