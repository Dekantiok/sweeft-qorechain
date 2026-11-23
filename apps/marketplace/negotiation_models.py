"""Negotiation — AI bargains against a listing's seller floor.

A negotiation is an off-chain agreement that only becomes real when the seller
accepts it (and updates the on-chain price to match) or the AI buys at the
list price. The seller's floor is never revealed to the AI — the tool returns
accept/reject/counter without disclosing the floor number.
"""

from __future__ import annotations

from django.db import models

from apps.marketplace.models import Listing
from apps.participants.models import Participant


class Negotiation(models.Model):
    class State(models.TextChoices):
        OPEN = "open", "Open"
        ACCEPTED = "accepted", "Accepted"
        REJECTED = "rejected", "Rejected"
        COUNTERED = "countered", "Countered"
        EXPIRED = "expired", "Expired"

    listing = models.ForeignKey(Listing, on_delete=models.PROTECT, related_name="negotiations")
    buyer = models.ForeignKey(Participant, on_delete=models.PROTECT, related_name="negotiations")
    proposed_uqor = models.DecimalField(max_digits=30, decimal_places=0)
    counter_uqor = models.DecimalField(max_digits=30, decimal_places=0, null=True, blank=True)
    details = models.TextField(blank=True)
    state = models.CharField(max_length=16, choices=State.choices, default=State.OPEN)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"Negotiation #{self.pk} on listing #{self.listing.on_chain_id} [{self.state}]"
