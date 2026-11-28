"""Seller-agent negotiation tests (Phase 3).

Run with: python manage.py test tests.test_seller_agent tests.test_ai_tools
"""

from __future__ import annotations

import json
from datetime import timedelta

from django.test import Client, TestCase
from django.utils import timezone

from apps.ai.models import Mandate, SellerAgentMandate
from apps.ai.services.seller_agent import ai_recommendation, evaluate_offer
from apps.ai.services.tools import execute_tool
from apps.marketplace.models import Listing
from apps.marketplace.negotiation_models import Negotiation
from apps.participants.models import Participant


class SellerAgentTests(TestCase):
    def setUp(self):
        self.buyer = Participant.objects.create(
            display_name="Buyer", evm_address="0xsabuyer", qor_address="qor1sab"
        )
        self.seller = Participant.objects.create(
            display_name="Seller", evm_address="0xsaseller", qor_address="qor1sas"
        )
        self.stranger = Participant.objects.create(
            display_name="Stranger", evm_address="0xsastranger", qor_address="qor1sast"
        )
        Mandate.objects.create(
            owner=self.buyer,
            per_tx_limit_uqor=10_000_000,
            daily_limit_uqor=100_000_000,
            state=Mandate.State.ACTIVE,
            expires_at=timezone.now() + timedelta(days=7),
        )
        # Listing priced 0.05 QOR; seller-agent floor 0.04, target 0.046.
        self.listing = Listing.objects.create(
            on_chain_id=21,
            seller=self.seller,
            title="Seller lamp",
            description="Brass lamp",
            price_uqor=50_000,
            floor_price_uqor=40_000,
            auto_accept_floor=False,
            quantity=3,
            status=Listing.Status.ACTIVE,
            metadata_hash="0x" + "cd" * 32,
        )
        self.mandate = SellerAgentMandate.objects.create(
            listing=self.listing,
            seller=self.seller,
            floor_uqor=40_000,
            target_uqor=46_000,
            strategy=SellerAgentMandate.Strategy.BALANCED,
            max_rounds=5,
            auto_accept=True,
            state=SellerAgentMandate.State.ACTIVE,
            expires_at=timezone.now() + timedelta(days=30),
        )

    def _login(self, client, participant):
        session = client.session
        session["wallet_account"] = {
            "evm": participant.evm_address,
            "qor": participant.qor_address,
            "method": "evm",
        }
        session.save()

    def test_floor_reject(self):
        # Direct evaluation: far below floor -> rejected, bucket, no leak.
        decision = evaluate_offer(self.listing, 20_000, rounds_used=0)
        self.assertEqual(decision["status"], "rejected")
        self.assertEqual(decision["reason"], "below_floor")
        self.assertIn(decision.get("distance_bucket"), ("far", "very_far", "near", "close"))
        self.assertNotIn("floor_uqor", json.dumps(decision))
        self.assertNotIn("floor_qor", json.dumps(decision))
        self.assertNotIn("target_uqor", json.dumps(decision))

        # End-to-end via tool_negotiate.
        result = execute_tool(
            "negotiate", wallet=self.buyer.evm_address, listing_id=21, offered_qor=0.02
        )
        self.assertEqual(result["status"], "rejected")
        self.assertFalse(result.get("auto_accept", False))
        blob = json.dumps(result)
        self.assertNotIn("40000", blob)
        self.assertNotIn("46000", blob)
        self.assertNotIn("floor_uqor", blob)
        self.assertNotIn("target_uqor", blob)

    def test_target_accept(self):
        result = execute_tool(
            "negotiate", wallet=self.buyer.evm_address, listing_id=21, offered_qor=0.05
        )
        self.assertEqual(result["status"], "accepted")
        self.assertTrue(result.get("auto_accept"))
        self.assertIn("negotiation_id", result)
        blob = json.dumps(result)
        self.assertNotIn("40000", blob)
        self.assertNotIn("46000", blob)
        self.assertNotIn("floor_uqor", blob)
        self.assertNotIn("floor_qor", blob)
        self.assertNotIn("target_uqor", blob)
        self.assertNotIn("target_qor", blob)

    def test_counter_banding(self):
        # Direct: midpoint (42k+46k)/2 = 44k banded up to 0.05 QOR.
        decision = evaluate_offer(self.listing, 42_000, rounds_used=0)
        self.assertEqual(decision["status"], "countered")
        self.assertEqual(decision["counter_uqor"], 44_000)
        self.assertEqual(decision["counter_qor"], 0.05)
        self.assertAlmostEqual(decision["counter_qor"] / 0.05, round(decision["counter_qor"] / 0.05))
        self.assertEqual(decision["counter_qor"], 0.05)

        result = execute_tool(
            "negotiate", wallet=self.buyer.evm_address, listing_id=21, offered_qor=0.042
        )
        self.assertEqual(result["status"], "countered")
        self.assertEqual(result["counter_qor"], 0.05)
        self.assertFalse(result.get("auto_accept"))
        self.assertNotIn("46000", json.dumps(result))
        self.assertNotIn("40000", json.dumps(result))

    def test_expired_mandate(self):
        self.mandate.expires_at = timezone.now() - timedelta(days=1)
        self.mandate.save(update_fields=["expires_at"])

        # evaluate_offer refuses with mandate_expired.
        decision = evaluate_offer(self.listing, 50_000, rounds_used=0)
        self.assertEqual(decision["status"], "rejected")
        self.assertEqual(decision["reason"], "mandate_expired")

        # tool_negotiate must NOT auto-accept via the expired mandate.
        result = execute_tool(
            "negotiate", wallet=self.buyer.evm_address, listing_id=21, offered_qor=0.05
        )
        self.assertFalse(result.get("auto_accept", False))
        self.assertNotEqual(result["status"], "accepted")
        # Expired mandate is transitioned out of ACTIVE.
        self.mandate.refresh_from_db()
        self.assertEqual(self.mandate.state, SellerAgentMandate.State.EXPIRED)

    def test_round_limit(self):
        # Exhaust max_rounds (5) with prior negotiations.
        for _ in range(5):
            Negotiation.objects.create(
                listing=self.listing,
                buyer=self.buyer,
                proposed_uqor=30_000,
                state=Negotiation.State.REJECTED,
            )
        decision = evaluate_offer(self.listing, 50_000, rounds_used=5)
        self.assertEqual(decision["status"], "rejected")
        self.assertEqual(decision["reason"], "round_limit_exceeded")

        result = execute_tool(
            "negotiate", wallet=self.buyer.evm_address, listing_id=21, offered_qor=0.05
        )
        self.assertEqual(result["status"], "rejected")
        self.assertEqual(result.get("reason"), "round_limit_exceeded")
        self.assertFalse(result.get("auto_accept"))
        self.assertEqual(result["rounds_used"], 5)
        self.assertEqual(result["max_rounds"], 5)

    def test_ownership_enforcement(self):
        client = Client()
        self._login(client, self.stranger)
        r = client.post(
            "/api/ai/seller-mandate/",
            data=json.dumps(
                {
                    "listing_id": 21,
                    "floor_qor": 0.04,
                    "target_qor": 0.046,
                    "max_rounds": 5,
                    "auto_accept": True,
                }
            ),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 403)
        self.assertNotEqual(
            SellerAgentMandate.objects.filter(
                listing=self.listing, seller=self.stranger
            ).count(),
            1,
        )

    def test_seller_can_set_mandate_and_get_status_without_leak(self):
        client = Client()
        self._login(client, self.seller)
        r = client.post(
            "/api/ai/seller-mandate/",
            data=json.dumps(
                {
                    "listing_id": 21,
                    "floor_qor": 0.04,
                    "target_qor": 0.046,
                    "max_rounds": 5,
                    "auto_accept": True,
                }
            ),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["ok"])

        r2 = client.get("/api/ai/seller-mandate/21/")
        self.assertEqual(r2.status_code, 200)
        body = r2.json()
        self.assertEqual(body["state"], "active")
        self.assertTrue(body["active"])
        blob = json.dumps(body)
        self.assertNotIn("40000", blob)
        self.assertNotIn("46000", blob)
        self.assertNotIn("floor_uqor", blob)
        self.assertNotIn("target_uqor", blob)

    def test_ai_recommendation_stats(self):
        Listing.objects.create(
            on_chain_id=99,
            seller=self.seller,
            title="Sold lamp",
            description="sold",
            price_uqor=60_000,
            quantity=1,
            status=Listing.Status.SOLD,
        )
        rec = ai_recommendation(self.listing)
        self.assertIn("median_sold_qor", rec)
        self.assertIn("price_ratio", rec)
        self.assertNotIn("floor_uqor", json.dumps(rec))
