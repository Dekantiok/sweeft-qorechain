"""AI tool unit tests: unit conversions + floor negotiation (B-13 follow-up).

Run with: python manage.py test tests.test_ai_tools
"""

from __future__ import annotations

from datetime import timedelta

from django.test import TestCase
from django.utils import timezone

from apps.ai.models import AgentAction, Mandate
from apps.ai.services.tools import execute_tool, tool_check_mandate, tool_search_listings
from apps.marketplace.models import Listing
from apps.marketplace.negotiation_models import Negotiation
from apps.participants.models import Participant


class ToolsUnitTests(TestCase):
    def setUp(self):
        self.buyer = Participant.objects.create(
            display_name="Buyer", evm_address="0xaitbuyer", qor_address="qor1ab"
        )
        self.seller = Participant.objects.create(
            display_name="Seller", evm_address="0xaittseller", qor_address="qor1as"
        )
        Mandate.objects.create(
            owner=self.buyer,
            per_tx_limit_uqor=500_000,  # 0.5 QOR
            daily_limit_uqor=2_000_000,  # 2 QOR
            state=Mandate.State.ACTIVE,
            expires_at=timezone.now() + timedelta(days=7),
        )
        # Listing priced 0.05 QOR with a 0.04 QOR floor.
        self.listing = Listing.objects.create(
            on_chain_id=11,
            seller=self.seller,
            title="Desk lamp",
            description="Brass lamp",
            price_uqor=50_000,
            floor_price_uqor=40_000,
            auto_accept_floor=True,
            quantity=3,
            status=Listing.Status.ACTIVE,
            metadata_hash="0x" + "ab" * 32,
        )

    def test_search_reports_correct_qor_price(self):
        # Regression: prices were divided by 1e12 (micro-QOR shown as 0.0).
        result = tool_search_listings(query="lamp", max_price_qor=None)
        prices = [l["price_qor"] for l in result["listings"]]
        self.assertIn(0.05, prices)

    def test_negotiate_above_floor_accepted(self):
        result = execute_tool(
            "negotiate", wallet=self.buyer.evm_address, listing_id=11, offered_qor=0.045
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["status"], "accepted")
        self.assertEqual(result["offered_qor"], 0.045)
        neg = Negotiation.objects.get(pk=result["negotiation_id"])
        self.assertEqual(int(neg.proposed_uqor), 45_000)  # uqor, not wei

    def test_negotiate_below_floor_countered(self):
        result = execute_tool(
            "negotiate", wallet=self.buyer.evm_address, listing_id=11, offered_qor=0.035
        )
        # 0.035 is within 20% of the 0.04 floor -> counter at the midpoint 0.0375
        self.assertEqual(result["status"], "countered")
        self.assertAlmostEqual(result["counter_qor"], 0.0375, places=6)

    def test_negotiate_far_below_floor_rejected(self):
        result = execute_tool(
            "negotiate", wallet=self.buyer.evm_address, listing_id=11, offered_qor=0.02
        )
        self.assertEqual(result["status"], "rejected")

    def test_negotiate_over_budget_refused(self):
        result = execute_tool(
            "negotiate", wallet=self.buyer.evm_address, listing_id=11, offered_qor=5.0
        )
        self.assertIn("error", result)

    def test_check_mandate_units(self):
        ok = tool_check_mandate("purchase", amount_qor=0.3, wallet=self.buyer.evm_address)
        self.assertTrue(ok["within_caps"])
        self.assertEqual(ok["amount_uqor"], 300_000)
