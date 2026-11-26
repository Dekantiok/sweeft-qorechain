"""Public API v1 tests (read-only, no auth, rate-limited).

Run with: python manage.py test tests.test_api
"""

from __future__ import annotations

from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import Client, TestCase
from django.utils import timezone

from apps.commerce.models import Order
from apps.escrow.models import Escrow
from apps.governance.models import Proposal
from apps.marketplace.models import Listing
from apps.participants.models import Participant


class ApiV1Tests(TestCase):
    def setUp(self):
        cache.clear()
        self.buyer = Participant.objects.create(
            display_name="Buyer", evm_address="0xapibuyer", qor_address="qor1ab"
        )
        self.seller = Participant.objects.create(
            display_name="Seller", evm_address="0xapiseller", qor_address="qor1as"
        )
        self.listing = Listing.objects.create(
            on_chain_id=7,
            seller=self.seller,
            title="Desk lamp",
            description="Brass lamp",
            price_uqor=2_000_000,
            quantity=3,
            status=Listing.Status.ACTIVE,
            metadata_hash="0x" + "ab" * 32,
        )
        self.order = Order.objects.create(
            buyer=self.buyer, seller=self.seller, unit_price_uqor=100, total_uqor=100
        )
        self.escrow = Escrow.objects.create(
            on_chain_id=5,
            order=self.order,
            buyer=self.buyer,
            seller=self.seller,
            amount_uqor=100_000,
            delivery_deadline=timezone.now() + timedelta(days=7),
        )
        self.client = Client()

    def test_index_lists_components(self):
        r = self.client.get("/api/v1/")
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertIn("listings", body["components"])
        self.assertIn("escrows", body["components"])
        self.assertIn("vault", body["contracts"])

    def test_listings(self):
        r = self.client.get("/api/v1/listings/")
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertEqual(body["count"], 1)
        item = body["results"][0]
        self.assertEqual(item["on_chain_id"], 7)
        self.assertEqual(item["price_qor"], "2")
        self.assertEqual(item["seller"], "0xapiseller")

    def test_listing_detail_and_404(self):
        r = self.client.get("/api/v1/listings/7/")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["title"], "Desk lamp")
        cache.clear()
        self.assertEqual(self.client.get("/api/v1/listings/999/").status_code, 404)

    def test_listings_status_filter(self):
        r = self.client.get("/api/v1/listings/?status=active")
        self.assertEqual(r.json()["count"], 1)
        cache.clear()
        r = self.client.get("/api/v1/listings/?status=sold")
        self.assertEqual(r.json()["count"], 0)

    def test_escrows_and_filter(self):
        r = self.client.get("/api/v1/escrows/")
        self.assertEqual(r.json()["count"], 1)
        cache.clear()
        r = self.client.get("/api/v1/escrows/?seller=0xapiseller")
        self.assertEqual(r.json()["count"], 1)
        cache.clear()
        r = self.client.get("/api/v1/escrows/?seller=0xnobody")
        self.assertEqual(r.json()["count"], 0)

    def test_escrow_detail(self):
        fake_live = {"status": 1, "release_eligible": True}
        with mock.patch("apps.blockchain.services.reads.escrow_state", return_value=fake_live):
            r = self.client.get("/api/v1/escrows/5/")
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertEqual(body["amount_qor"], "0.1")
        self.assertEqual(body["live"], fake_live)
        self.assertIn("/proof/escrow/5/", body["proof"])

    def test_escrow_detail_404(self):
        self.assertEqual(self.client.get("/api/v1/escrows/999/").status_code, 404)

    def test_disputes_empty(self):
        r = self.client.get("/api/v1/disputes/")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["results"], [])

    def test_proposals(self):
        Proposal.objects.create(
            proposer=self.buyer,
            kind=Proposal.Kind.VERIFIER_APPROVAL,
            title="Approve verifier",
            description="Adds a verifier",
            voting_ends_at=timezone.now() + timedelta(days=1),
        )
        r = self.client.get("/api/v1/proposals/")
        self.assertEqual(r.json()["count"], 1)
        self.assertEqual(r.json()["results"][0]["votes_for"], 0)

    def test_verifiers_empty(self):
        r = self.client.get("/api/v1/verifiers/")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["results"], [])

    def test_board_chain_failure_is_502(self):
        with mock.patch("apps.blockchain.services.reads.board_state", side_effect=RuntimeError("down")):
            r = self.client.get("/api/v1/board/")
        self.assertEqual(r.status_code, 502)

    def test_rate_limit_second_call_429(self):
        r1 = self.client.get("/api/v1/listings/")
        self.assertEqual(r1.status_code, 200)
        r2 = self.client.get("/api/v1/listings/")
        self.assertEqual(r2.status_code, 429)

    def test_bad_pagination_400(self):
        r = self.client.get("/api/v1/listings/?limit=abc")
        self.assertEqual(r.status_code, 400)
