"""Commerce — orders connecting buyers to listings and escrows."""

from __future__ import annotations

from django.db import models

from apps.marketplace.models import Listing
from apps.participants.models import Participant


class Order(models.Model):
    class State(models.TextChoices):
        PENDING = "pending", "Pending escrow"
        ESCROW_CREATED = "escrow_created", "Escrow created"
        FUNDED = "funded", "Funded"
        COMPLETED = "completed", "Completed"
        CANCELLED = "cancelled", "Cancelled"

    reference = models.CharField(max_length=24, unique=True, help_text="Human-friendly order reference")
    listing = models.ForeignKey(
        Listing, on_delete=models.PROTECT, related_name="orders", null=True, blank=True,
        help_text="Absent for direct escrows created outside the marketplace",
    )
    buyer = models.ForeignKey(Participant, on_delete=models.PROTECT, related_name="orders")
    seller = models.ForeignKey(Participant, on_delete=models.PROTECT, related_name="sales")

    quantity = models.PositiveIntegerField(default=1)
    unit_price_uqor = models.DecimalField(max_digits=30, decimal_places=0)
    total_uqor = models.DecimalField(max_digits=30, decimal_places=0)

    state = models.CharField(max_length=16, choices=State.choices, default=State.PENDING)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.reference} — {self.listing.title if self.listing else 'direct escrow'}"

    @property
    def total_qor(self) -> str:
        return f"{int(self.total_uqor) / 1_000_000:.6f}".rstrip("0").rstrip(".")

    def save(self, *args, **kwargs):
        if not self.reference:
            import secrets

            self.reference = f"SW-{secrets.token_hex(4).upper()}"
        super().save(*args, **kwargs)
