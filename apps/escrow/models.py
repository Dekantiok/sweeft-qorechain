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
