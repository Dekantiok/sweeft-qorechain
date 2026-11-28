"""AI on the landing page and budget in the wallet menu.

Run with python manage.py test tests.test_ai_landing
"""

from __future__ import annotations

from datetime import timedelta

from django.test import Client, TestCase
from django.utils import timezone

from apps.ai.models import Mandate
from apps.participants.models import Participant


class AiLandingTests(TestCase):
    def setUp(self):
        self.buyer = Participant.objects.create(
            display_name="Buyer", evm_address="0xailandingbuyer00000000000000000000001",
            qor_address="qor1ailanding",
        )
        Mandate.objects.create(
            owner=self.buyer, per_tx_limit_uqor=500_000, daily_limit_uqor=2_000_000,
            state=Mandate.State.ACTIVE, expires_at=timezone.now() + timedelta(days=7),
        )
        self.client = Client()

    def _connect(self):
        session = self.client.session
        session["wallet_account"] = {
            "evm": self.buyer.evm_address, "qor": self.buyer.qor_address, "method": "evm",
        }
        session.save()

    def test_landing_shows_connect_prompt_when_logged_out(self):
        r = self.client.get("/")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Connect your wallet to chat")
        self.assertNotContains(r, 'id="chat-input"')

    def test_landing_shows_chat_when_connected(self):
        self._connect()
        r = self.client.get("/")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, 'id="chat-input"')
        self.assertContains(r, "AI assistant budget")
        self.assertContains(r, "0.5 QOR")

    def test_fresh_wallet_without_participant_row_sees_chat(self):
        # Regression: a connected wallet with no Participant row (indexer has
        # not seen it on chain) was shown the Connect prompt and no chat.
        fresh = "0xfreshwallet000000000000000000000000001"
        self.assertFalse(Participant.objects.filter(evm_address__iexact=fresh).exists())
        session = self.client.session
        session["wallet_account"] = {"evm": fresh, "qor": "qor1fresh", "method": "evm"}
        session.save()
        r = self.client.get("/")
        self.assertContains(r, 'id="chat-input"')
        self.assertNotContains(r, "Connect your wallet to chat")
        # First AI use provisions the participant so the budget form works.
        r = self.client.post(
            "/api/ai/mandate/", {"per_tx_qor": "0.5", "daily_qor": "2", "days": "7"}
        )
        self.assertEqual(r.status_code, 200)

    def test_ai_page_redirects_to_landing_anchor(self):
        r = self.client.get("/ai/")
        self.assertEqual(r.status_code, 302)
        self.assertEqual(r.url, "/#ai-assistant")
