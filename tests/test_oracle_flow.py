"""Verifier attestation endpoint tests (Phase 3 flow).

Run with: python manage.py test tests.test_oracle_flow
"""

from __future__ import annotations

import json
from datetime import timedelta
from unittest import mock

from django.test import Client, TestCase
from django.utils import timezone

from apps.commerce.models import Order
from apps.escrow.models import Escrow
from apps.oracle.models import FulfilmentEvidence
from apps.participants.models import Participant


class VerifierAttestEndpointTests(TestCase):
    def setUp(self):
        self.buyer = Participant.objects.create(
            display_name="Buyer", evm_address="0x" + "ab" * 20, qor_address="qor1ob"
        )
        self.seller = Participant.objects.create(
            display_name="Seller", evm_address="0x" + "cd" * 20, qor_address="qor1os"
        )
        self.order = Order.objects.create(
            buyer=self.buyer, seller=self.seller, unit_price_uqor=100, total_uqor=100
        )
        self.escrow = Escrow.objects.create(
            on_chain_id=9,
            order=self.order,
            buyer=self.buyer,
            seller=self.seller,
            amount_uqor=100_000,
            delivery_deadline=timezone.now() + timedelta(days=7),
        )
        self.evidence = FulfilmentEvidence.objects.create(
            escrow=self.escrow,
            submitted_by=self.seller,
            evidence_type="carrier_receipt",
            description="proof",
            content_hash="0x" + "ab" * 32,
        )
        self.client = Client()

    def _login(self, participant):
        session = self.client.session
        session["wallet_account"] = {"evm": participant.evm_address, "qor": participant.qor_address, "method": "evm"}
        session.save()

    def test_attest_request_requires_wallet(self):
        r = self.client.get(f"/api/oracle/attest-request/?escrow_id=9&evidence_id={self.evidence.pk}")
        self.assertEqual(r.status_code, 401)

    def test_attest_request_rejects_non_verifier(self):
        self._login(self.buyer)
        with mock.patch("apps.oracle.views.is_verifier", return_value=False):
            r = self.client.get(f"/api/oracle/attest-request/?escrow_id=9&evidence_id={self.evidence.pk}")
        self.assertEqual(r.status_code, 403)

    def test_attest_request_builds_message(self):
        self._login(self.seller)
        with mock.patch("apps.oracle.views.is_verifier", return_value=True), mock.patch(
            "apps.blockchain.services.reads._vault_contract"
        ) as mock_vault, mock.patch("apps.blockchain.services.reads.get_evm_client"):
            vault = mock_vault.return_value
            vault.functions.verifierNonce.return_value.call.return_value = 0
            registry = mock.MagicMock()
            registry.functions.keyVersion.return_value.call.return_value = 1
            with mock.patch("apps.oracle.views.make_contract" if False else "integrations.qorechain.contracts_base.make_contract", return_value=registry):
                r = self.client.get(f"/api/oracle/attest-request/?escrow_id=9&evidence_id={self.evidence.pk}")
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertTrue(body["message"].startswith("sweeft-verifier-v1|"))
        self.assertEqual(body["key_version"], 1)

    def test_attest_submit_relays(self):
        self._login(self.seller)
        payload = {
            "escrow_id": 9,
            "verifier": "0x" + "ab" * 20,
            "evidence_hash": "0x" + "ab" * 32,
            "issued_at": 1000,
            "expires_at": 1000 + 604800,
            "evidence_id": self.evidence.pk,
            "signature_pq_hex": "0x" + "cd" * 100,
        }
        with mock.patch(
            "apps.blockchain.services.relayer.submit_verifier_attestation",
            return_value={"tx_hash": "0xdead", "block": 1},
        ) as submit:
            r = self.client.post(
                "/api/oracle/attest-submit/", data=json.dumps(payload), content_type="application/json"
            )
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["ok"])
        args = submit.call_args.args
        self.assertEqual(args[0], 9)
        self.assertEqual(args[1], payload["verifier"])

    def test_attest_submit_malformed_400(self):
        self._login(self.seller)
        r = self.client.post(
            "/api/oracle/attest-submit/", data=json.dumps({"escrow_id": "x"}), content_type="application/json"
        )
        self.assertEqual(r.status_code, 400)
