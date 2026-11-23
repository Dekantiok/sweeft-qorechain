"""Backend security regression tests (audit items B-1, B-3, B-6, B-8, B-11).

Run with: python manage.py test tests
"""

from __future__ import annotations

import json
import time
from datetime import timedelta

from django.test import Client, TestCase
from django.utils import timezone

from apps.ai.models import Mandate
from apps.ai.services.tools import tool_check_mandate
from apps.commerce.models import Order
from apps.escrow.models import Escrow
from apps.participants.models import Participant


class SecurityEndpointTests(TestCase):
    def setUp(self):
        self.buyer = Participant.objects.create(
            display_name="Buyer", evm_address="0xbuyer", qor_address="qor1buyer"
        )
        self.seller = Participant.objects.create(
            display_name="Seller", evm_address="0xseller", qor_address="qor1seller"
        )
        self.stranger = Participant.objects.create(
            display_name="Stranger", evm_address="0xstranger", qor_address="qor1stranger"
        )
        self.order = Order.objects.create(
            buyer=self.buyer, seller=self.seller, unit_price_uqor=100, total_uqor=100
        )
        self.escrow = Escrow.objects.create(
            on_chain_id=1,
            order=self.order,
            buyer=self.buyer,
            seller=self.seller,
            amount_uqor=100,
            delivery_deadline=timezone.now() + timedelta(days=7),
        )
        self.client = Client()

    def _login(self, participant: Participant):
        session = self.client.session
        session["wallet_account"] = {"evm": participant.evm_address, "qor": participant.qor_address, "method": "evm"}
        session.save()

    # -- B-1: autopilot auth -------------------------------------------------

    def test_autopilot_pre_authorize_requires_wallet(self):
        r = self.client.post(
            "/api/escrow/1/autopilot/pre-authorize/",
            data=json.dumps({"signature_pq_b64": "AA=="}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 401)

    def test_autopilot_pre_authorize_rejects_non_buyer(self):
        self._login(self.stranger)
        r = self.client.post(
            "/api/escrow/1/autopilot/pre-authorize/",
            data=json.dumps({"signature_pq_b64": "AA=="}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 403)

    def test_autopilot_revoke_requires_wallet(self):
        r = self.client.post("/api/escrow/1/autopilot/revoke/")
        self.assertEqual(r.status_code, 401)

    def test_autopilot_execute_rejects_unauthorized(self):
        r = self.client.post("/api/escrow/1/autopilot/execute/")
        self.assertEqual(r.status_code, 403)

    def test_release_submit_rejects_bad_signature_length(self):
        r = self.client.post(
            "/api/escrow/1/release/",
            data=json.dumps({"signature_pq_b64": "AA=="}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 400)

    # -- B-3: indexer trigger ------------------------------------------------

    def test_sync_now_rejects_unauthenticated(self):
        r = self.client.post("/api/indexer/sync/")
        self.assertEqual(r.status_code, 403)

    # -- B-6: evidence party check ------------------------------------------

    def test_evidence_requires_wallet(self):
        r = self.client.post(
            "/api/escrow/1/evidence/",
            data=json.dumps({"description": "hi"}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 401)

    def test_evidence_rejects_non_party(self):
        self._login(self.stranger)
        r = self.client.post(
            "/api/escrow/1/evidence/",
            data=json.dumps({"description": "hi"}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 403)


class WalletLoginTests(TestCase):
    def test_challenge_expires(self):
        client = Client()
        r = client.get("/api/wallet/challenge/?address=qor1abc")
        self.assertEqual(r.status_code, 200)
        message = r.json()["message"]

        # Backdate the challenge beyond the TTL.
        session = client.session
        session["wallet_challenge"]["issued_at"] = time.time() - 10_000
        session.save()

        r = client.post(
            "/api/wallet/verify/",
            data=json.dumps({"method": "evm", "address": "qor1abc", "message": message, "signature": "0x00"}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 400)

    def test_challenge_is_single_use_on_failure(self):
        client = Client()
        r = client.get("/api/wallet/challenge/?address=qor1abc")
        message = r.json()["message"]
        client.post(
            "/api/wallet/verify/",
            data=json.dumps({"method": "evm", "address": "qor1abc", "message": message, "signature": "0x00"}),
            content_type="application/json",
        )
        # The challenge is cleared, so a second attempt fails as a mismatch.
        r = client.post(
            "/api/wallet/verify/",
            data=json.dumps({"method": "evm", "address": "qor1abc", "message": message, "signature": "0x00"}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 400)


class MandateTests(TestCase):
    def setUp(self):
        self.buyer = Participant.objects.create(
            display_name="Buyer", evm_address="0xmandatebuyer", qor_address="qor1mb"
        )

    def test_no_mandate_refuses_autonomous_spend(self):
        result = tool_check_mandate("purchase", amount_qor=0.1, wallet=self.buyer.evm_address)
        self.assertFalse(result["within_caps"])

    def test_per_tx_cap_enforced(self):
        Mandate.objects.create(
            owner=self.buyer,
            per_tx_limit_uqor=1_000_000,  # 1 QOR
            daily_limit_uqor=5_000_000,
            state=Mandate.State.ACTIVE,
            expires_at=timezone.now() + timedelta(days=30),
        )
        ok = tool_check_mandate("purchase", amount_qor=0.5, wallet=self.buyer.evm_address)
        self.assertTrue(ok["within_caps"])

        too_big = tool_check_mandate("purchase", amount_qor=5, wallet=self.buyer.evm_address)
        self.assertFalse(too_big["within_caps"])

    def test_expired_mandate_refused(self):
        Mandate.objects.create(
            owner=self.buyer,
            per_tx_limit_uqor=10_000_000,
            daily_limit_uqor=10_000_000,
            state=Mandate.State.ACTIVE,
            expires_at=timezone.now() - timedelta(days=1),
        )
        result = tool_check_mandate("purchase", amount_qor=0.5, wallet=self.buyer.evm_address)
        self.assertFalse(result["within_caps"])
