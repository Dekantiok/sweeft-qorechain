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
from apps.ai.services.tools import _active_mandate, execute_tool, tool_check_mandate, tool_execute_autopilot
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

    def test_metadata_requires_wallet(self):
        r = self.client.post(
            "/api/marketplace/metadata/",
            data=json.dumps({"title": "lamp", "seller_evm": "0xattacker"}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 401)

    def test_metadata_ignores_client_seller(self):
        self._login(self.buyer)
        r = self.client.post(
            "/api/marketplace/metadata/",
            data=json.dumps({"title": "lamp", "seller_evm": "0xattacker"}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["metadata"]["seller_evm"], "0xbuyer")


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

    # -- mixed address forms (mobile 500 regression) ---------------------

    def _set_challenge(self, client, address, message):
        session = client.session
        session["wallet_challenge"] = {
            "message": message,
            "address": address.lower(),
            "issued_at": time.time(),
            "domain": "testserver",
        }
        session.save()

    def test_verify_evm_path_with_qor_address_converts(self):
        """Mobile regression: a qor1 address via the EVM method must convert,
        not 500."""
        client = Client()
        from qorsdk.address import hex_to_bech32

        qor = hex_to_bech32("0x1111111111111111111111111111111111111111")
        message = "Sweeft login\ndomain: testserver\naddress: " + qor
        self._set_challenge(client, qor, message)

        # Reuse a real EIP-191 signature from a known key.
        from eth_account import Account

        key = "0x" + "11" * 32
        signed = Account.sign_message(
            __import__("eth_account.messages", fromlist=["encode_defunct"]).encode_defunct(text=message),
            key,
        )
        r = client.post(
            "/api/wallet/verify/",
            data=json.dumps(
                {
                    "method": "evm",
                    "address": qor,
                    "message": message,
                    "signature": signed.signature.hex(),
                }
            ),
            content_type="application/json",
        )
        # The recovered signer is the EVM form, not the qor1 form, so this
        # legitimately fails as a mismatch — but it must be a 400/401 JSON
        # response and NEVER a 500.
        self.assertIn(r.status_code, (400, 401))
        self.assertIn("error", r.json())

    def test_verify_unknown_address_format_is_400_not_500(self):
        client = Client()
        message = "Sweeft login\ndomain: testserver\naddress: nonsense"
        self._set_challenge(client, "nonsense", message)
        r = client.post(
            "/api/wallet/verify/",
            data=json.dumps({"method": "evm", "address": "nonsense", "message": message, "signature": "0x00"}),
            content_type="application/json",
        )
        # Malformed signatures are rejected (401) — the point is a JSON
        # error, never a 500.
        self.assertIn(r.status_code, (400, 401))
        self.assertIn("error", r.json())

    def test_verify_evm_method_normalizes_0x_address(self):
        """A valid EVM signature logs the wallet in (session + dual forms)."""
        client = Client()
        from eth_account import Account
        from eth_account.messages import encode_defunct
        from qorsdk.address import hex_to_bech32

        key = "0x" + "22" * 32
        evm = Account.from_key(key).address
        message = "Sweeft login\ndomain: testserver\naddress: " + evm
        self._set_challenge(client, evm, message)
        signed = Account.sign_message(encode_defunct(text=message), key)
        r = client.post(
            "/api/wallet/verify/",
            data=json.dumps(
                {"method": "evm", "address": evm, "message": message, "signature": signed.signature.hex()}
            ),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertEqual(body["evm"].lower(), evm.lower())
        self.assertEqual(body["qor"], hex_to_bech32(evm))


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


class MandateWalletBindingTests(TestCase):
    """N-11: a mandate must never be resolved for the wrong (or no) wallet."""

    def setUp(self):
        self.buyer = Participant.objects.create(
            display_name="Buyer", evm_address="0xboundbuyer", qor_address="qor1bb"
        )
        self.other = Participant.objects.create(
            display_name="Other", evm_address="0xboundother", qor_address="qor1bo"
        )
        Mandate.objects.create(
            owner=self.buyer,
            per_tx_limit_uqor=10_000_000,
            daily_limit_uqor=10_000_000,
            state=Mandate.State.ACTIVE,
            expires_at=timezone.now() + timedelta(days=30),
        )

    def test_active_mandate_none_wallet_returns_none(self):
        self.assertIsNone(_active_mandate(None))
        self.assertIsNone(_active_mandate(""))

    def test_active_mandate_does_not_leak_across_wallets(self):
        self.assertIsNotNone(_active_mandate(self.buyer.evm_address))
        self.assertIsNone(_active_mandate(self.other.evm_address))

    def test_check_mandate_none_wallet_refuses(self):
        result = tool_check_mandate("purchase", amount_qor=0.1, wallet=None)
        self.assertFalse(result["within_caps"])
        self.assertIn("no active mandate", result["reason"])

    def test_check_mandate_other_wallet_refuses(self):
        # The buyer has a mandate; the other wallet must not borrow it.
        result = tool_check_mandate("purchase", amount_qor=0.1, wallet=self.other.evm_address)
        self.assertFalse(result["within_caps"])

    def test_execute_tool_ignores_model_supplied_wallet(self):
        # Even if the model passes a victim wallet, the server-side wallet wins.
        result = execute_tool(
            "check_mandate",
            wallet=self.other.evm_address,
            action="purchase",
            amount_qor=0.1,
            wallet_supplied=self.buyer.evm_address,
        )
        # Server wallet is the other wallet, which has no mandate -> refused.
        self.assertFalse(result["within_caps"])

        result = execute_tool(
            "check_mandate",
            wallet=self.buyer.evm_address,
            action="purchase",
            amount_qor=0.1,
            wallet_supplied=self.other.evm_address,
        )
        self.assertTrue(result["within_caps"])


class AutopilotWalletBindingTests(TestCase):
    def setUp(self):
        self.buyer = Participant.objects.create(
            display_name="Buyer", evm_address="0xapbuyer", qor_address="qor1apb"
        )
        self.seller = Participant.objects.create(
            display_name="Seller", evm_address="0xapseller", qor_address="qor1aps"
        )
        self.order = Order.objects.create(
            buyer=self.buyer, seller=self.seller, unit_price_uqor=100, total_uqor=100
        )
        self.escrow = Escrow.objects.create(
            on_chain_id=7,
            order=self.order,
            buyer=self.buyer,
            seller=self.seller,
            amount_uqor=100,
            delivery_deadline=timezone.now() + timedelta(days=7),
            autopilot_enabled=True,
            autopilot_release_signature_b64="AA==",
        )

    def test_execute_autopilot_no_wallet_rejected(self):
        result = tool_execute_autopilot(7, wallet=None)
        self.assertIn("error", result)
        self.assertIn("not authorized", result["error"])

    def test_execute_autopilot_seller_rejected(self):
        result = tool_execute_autopilot(7, wallet=self.seller.evm_address)
        self.assertIn("error", result)
        self.assertIn("not authorized", result["error"])

    def test_execute_autopilot_other_buyer_rejected(self):
        stranger = Participant.objects.create(
            display_name="Stranger", evm_address="0xapstranger", qor_address="qor1aps2"
        )
        result = tool_execute_autopilot(7, wallet=stranger.evm_address)
        self.assertIn("error", result)
        self.assertIn("not authorized", result["error"])


class RateLimitHelperTests(TestCase):
    def _request(self, remote="127.0.0.1", forwarded=None):
        from django.test import RequestFactory

        req = RequestFactory().get("/")
        req.META["REMOTE_ADDR"] = remote
        if forwarded is not None:
            req.META["HTTP_X_FORWARDED_FOR"] = forwarded
        return req

    def test_client_ip_ignores_forwarded_by_default(self):
        from config.ratelimit import client_ip

        with self.settings():
            import os

            os.environ.pop("SWEEFT_TRUST_PROXY", None)
            req = self._request(remote="10.0.0.9", forwarded="1.2.3.4")
            self.assertEqual(client_ip(req), "10.0.0.9")

    def test_client_ip_uses_last_hop_when_trust_proxy(self):
        import os

        from config.ratelimit import client_ip

        old = os.environ.get("SWEEFT_TRUST_PROXY")
        os.environ["SWEEFT_TRUST_PROXY"] = "1"
        try:
            req = self._request(remote="10.0.0.9", forwarded="1.2.3.4, 5.6.7.8")
            # Last hop (appended by nearest trusted proxy), not the forgeable first.
            self.assertEqual(client_ip(req), "5.6.7.8")
        finally:
            if old is None:
                os.environ.pop("SWEEFT_TRUST_PROXY", None)
            else:
                os.environ["SWEEFT_TRUST_PROXY"] = old

    def test_is_rate_limited_second_call_within_window(self):
        from django.core.cache import cache

        from config.ratelimit import is_rate_limited

        cache.clear()
        req = self._request(remote="192.0.2.55")
        self.assertFalse(is_rate_limited("test-scope", req, 60))
        self.assertTrue(is_rate_limited("test-scope", req, 60))
        cache.clear()


class CspNonceTests(TestCase):
    def test_csp_nonce_exposed_and_header_substituted(self):
        from django.test import RequestFactory, override_settings

        from config.context_processors import csp_nonce
        from config.middleware import ContentSecurityPolicyMiddleware

        req = RequestFactory().get("/")
        req.csp_nonce = "test-nonce-123"
        self.assertEqual(csp_nonce(req)["csp_nonce"], "test-nonce-123")

        policy = "default-src 'self'; script-src 'self' 'nonce-{nonce}'; object-src 'none'"
        with override_settings(CONTENT_SECURITY_POLICY=policy):
            mw = ContentSecurityPolicyMiddleware(lambda r: __import__("django.http", fromlist=["HttpResponse"]).HttpResponse("ok"))
            mw.policy = policy
            resp = mw(req)
            header = resp["Content-Security-Policy"]
            self.assertIn("'nonce-", header)
            self.assertNotIn("{nonce}", header)
            self.assertIn("object-src 'none'", header)
            self.assertNotIn("'unsafe-inline'", header.split("script-src")[1].split(";")[0])

    def test_homepage_renders_nonce_attribute(self):
        import re

        client = Client()
        r = client.get("/")
        self.assertEqual(r.status_code, 200)
        # The middleware always sets a per-request nonce (prod CSP uses it).
        m = re.search(r'<script nonce="([^"]+)">', r.content.decode())
        self.assertIsNotNone(m)
        self.assertTrue(len(m.group(1)) >= 16)
        # No inline handlers / CDN scripts remain in the base template.
        body = r.content.decode()
        self.assertNotIn("cdn.tailwindcss.com", body)
        self.assertNotIn("unpkg.com", body)
        self.assertNotIn("alpinejs", body)
        self.assertNotIn("onclick=", body)
