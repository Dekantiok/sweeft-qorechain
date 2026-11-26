"""End-to-end smoke tests (Django test client, no browser required).

Covers the full demo journey a judge takes: marketplace renders listings,
an escrow detail page renders, the public API reflects the same data, and
the security page renders with relayer health. The browser/Playwright
suite (full wallet flows) is documented in tests/e2e/README.md — these
smoke tests run in CI with zero extra dependencies.

Run with: python manage.py test tests.e2e.test_smoke
"""

from __future__ import annotations

from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import Client, TestCase
from django.utils import timezone

from apps.commerce.models import Order
from apps.escrow.models import Escrow
from apps.marketplace.models import Listing
from apps.participants.models import Participant


class DemoJourneySmokeTests(TestCase):
    def setUp(self):
        cache.clear()
        self.buyer = Participant.objects.create(
            display_name="Buyer", evm_address="0xe2ebuyer", qor_address="qor1eb"
        )
        self.seller = Participant.objects.create(
            display_name="Seller", evm_address="0xe2eseller", qor_address="qor1es"
        )
        Listing.objects.create(
            on_chain_id=1, seller=self.seller, title="Smoke Lamp",
            description="E2E smoke listing", price_uqor=1_000_000, quantity=2,
            status=Listing.Status.ACTIVE, metadata_hash="0x" + "cd" * 32,
        )
        order = Order.objects.create(
            buyer=self.buyer, seller=self.seller, unit_price_uqor=1_000_000, total_uqor=1_000_000
        )
        Escrow.objects.create(
            on_chain_id=1, order=order, buyer=self.buyer, seller=self.seller,
            amount_uqor=1_000_000, delivery_deadline=timezone.now() + timedelta(days=7),
            state=Escrow.State.FUNDED,
        )
        self.client = Client()

    def test_marketplace_renders_listing(self):
        r = self.client.get("/marketplace/")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Smoke Lamp")

    def test_escrow_detail_renders(self):
        r = self.client.get("/escrow/1/")
        self.assertEqual(r.status_code, 200)

    def test_api_reflects_same_data(self):
        r = self.client.get("/api/v1/listings/")
        self.assertEqual(r.status_code, 200)
        body = r.json()
        items = body.get("listings") or body.get("results") or []
        titles = [item.get("title") for item in items]
        self.assertIn("Smoke Lamp", titles)

        with mock.patch(
            "apps.blockchain.services.reads.escrow_state", return_value={"status": 1}
        ):
            r = self.client.get("/api/v1/escrows/1/")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json().get("on_chain_id"), 1)

    def test_security_page_renders_with_relayer_card(self):
        r = self.client.get("/security/")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Relayer")
