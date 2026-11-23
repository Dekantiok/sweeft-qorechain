"""Escrow — mirror of on-chain escrow state.

The contract (SweeftVault.sol) is authoritative for money and state
transitions. This model tracks the off-chain view: references, deadlines,
transaction hashes and PQ nonce bookkeeping for building release signatures in
the browser.
"""

from __future__ import annotations

from django.db import models

from apps.commerce.models import Order
from apps.participants.models import Participant


class Escrow(models.Model):
    class State(models.TextChoices):
        CREATED = "created", "Created"
        FUNDED = "funded", "Funded"
        FULFILLED = "fulfilled", "Fulfilled (delivery pending)"
        DELIVERED = "delivered", "Delivered"
        RELEASE_ELIGIBLE = "release_eligible", "Release eligible"
        COMPLETED = "completed", "Completed"
        CANCELLED = "cancelled", "Cancelled"
        REFUNDED = "refunded", "Refunded"
        DISPUTED = "disputed", "Disputed"

    on_chain_id = models.PositiveBigIntegerField(unique=True)
    order = models.OneToOneField(Order, on_delete=models.PROTECT, related_name="escrow")

    buyer = models.ForeignKey(Participant, on_delete=models.PROTECT, related_name="escrows_as_buyer")
    seller = models.ForeignKey(Participant, on_delete=models.PROTECT, related_name="escrows_as_seller")

    amount_uqor = models.DecimalField(max_digits=30, decimal_places=0)
    delivery_deadline = models.DateTimeField()
    inspection_period_hours = models.PositiveIntegerField(default=48)

    # Logistics / carrier (v4) — physical vs digital delivery
    class DeliveryType(models.TextChoices):
        PHYSICAL = "physical", "Physical (carrier)"
        DIGITAL = "digital", "Digital (buyer confirmation)"

    delivery_type = models.CharField(max_length=16, choices=DeliveryType.choices, default=DeliveryType.PHYSICAL)
    logistics_partner_address = models.CharField(max_length=42, blank=True)
    logistics_amount_uqor = models.DecimalField(max_digits=30, decimal_places=0, default=0)
    carrier_attested = models.BooleanField(default=False)
    carrier_payload_hash = models.CharField(max_length=66, blank=True)

    # Platform fee (2% default), split treasury/dispute at release time
    fee_treasury_uqor = models.DecimalField(max_digits=30, decimal_places=0, default=0)
    fee_dispute_uqor = models.DecimalField(max_digits=30, decimal_places=0, default=0)

    state = models.CharField(max_length=20, choices=State.choices, default=State.CREATED)

    # PQC release bookkeeping — the browser signs with the buyer's ML-DSA-87 key.
    pqc_nonce = models.PositiveBigIntegerField(
        default=0, help_text="Per-buyer nonce of the last accepted release/refund signature"
    )

    # Transaction trail
    create_tx = models.CharField(max_length=80, blank=True)
    fund_tx = models.CharField(max_length=80, blank=True)
    release_tx = models.CharField(max_length=80, blank=True)
    refund_tx = models.CharField(max_length=80, blank=True)

    # Autopilot (pre-authorized release) — the buyer signs once in QoreX and the AI
    # submits that exact signature when the escrow becomes release-eligible.
    # The signed message already binds escrowId/recipient/amount/nonce, so the
    # scope of the pre-authorization cannot exceed the funded terms.
    autopilot_enabled = models.BooleanField(default=False)
    autopilot_release_signature_b64 = models.TextField(blank=True)
    autopilot_signer = models.CharField(max_length=42, blank=True)
    autopilot_authorized_at = models.DateTimeField(null=True, blank=True)
    autopilot_execute_tx = models.CharField(max_length=80, blank=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]
        verbose_name_plural = "escrows"

    def __str__(self) -> str:
        return f"Escrow #{self.on_chain_id} [{self.state}]"

    @property
    def amount_qor(self) -> str:
        return f"{int(self.amount_uqor) / 1_000_000:.6f}".rstrip("0").rstrip(".")
