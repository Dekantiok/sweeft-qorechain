"""Reputation — commercial trust from verified outcomes only.

Weights are application parameters (DAO-governed later); the score is computed
in Django from ReputationEvents. A transaction counts only when it completes
through the verified on-chain path — marking something completed without
satisfying verification rules does not count.
"""

from __future__ import annotations

from decimal import Decimal

from django.db import models

from apps.escrow.models import Escrow
from apps.participants.models import Participant

DEFAULT_WEIGHTS = {
    "successful_fulfilment": Decimal("0.40"),
    "completed_transactions": Decimal("0.25"),
    "buyer_feedback": Decimal("0.20"),
    "verification_reliability": Decimal("0.15"),
}


class ReputationProfile(models.Model):
    participant = models.OneToOneField(Participant, on_delete=models.CASCADE, related_name="reputation")

    total_transactions = models.PositiveIntegerField(default=0)
    successful_transactions = models.PositiveIntegerField(default=0)
    cancelled_transactions = models.PositiveIntegerField(default=0)
    verified_fulfilments = models.PositiveIntegerField(default=0)

    feedback_count = models.PositiveIntegerField(default=0)
    feedback_sum = models.PositiveIntegerField(default=0, help_text="Sum of 1-5 ratings")

    trust_score = models.DecimalField(max_digits=5, decimal_places=2, default=Decimal("0.00"))
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"Reputation of {self.participant.display_name}: {self.trust_score}"

    @property
    def average_feedback(self) -> float:
        if not self.feedback_count:
            return 0.0
        return self.feedback_sum / self.feedback_count

    def recompute_trust_score(self) -> Decimal:
        """Weighted score in [0, 100] from recorded events."""
        w = DEFAULT_WEIGHTS

        if self.total_transactions == 0:
            success_ratio = Decimal("0")
            volume_factor = Decimal("0")
        else:
            success_ratio = Decimal(self.successful_transactions) / Decimal(self.total_transactions)
            # Saturating volume factor: 10 completed transactions reaches full weight.
            volume_factor = min(Decimal(self.successful_transactions) / Decimal("10"), Decimal("1"))

        feedback_factor = (
            Decimal(str(self.average_feedback)) / Decimal("5") if self.feedback_count else Decimal("0")
        )
        verification_factor = (
            Decimal(self.verified_fulfilments) / Decimal(self.successful_transactions)
            if self.successful_transactions
            else Decimal("0")
        )

        score = (
            w["successful_fulfilment"] * success_ratio
            + w["completed_transactions"] * volume_factor
            + w["buyer_feedback"] * feedback_factor
            + w["verification_reliability"] * verification_factor
        ) * Decimal("100")

        self.trust_score = score.quantize(Decimal("0.01"))
        return self.trust_score


class ReputationEvent(models.Model):
    """One verified commercial outcome. Only the escrow completion service
    may create these; duplicates per escrow are rejected at the DB level."""

    class Kind(models.TextChoices):
        ESCROW_COMPLETED = "escrow_completed", "Escrow completed and released"
        ESCROW_REFUNDED = "escrow_refunded", "Escrow refunded by deadline"
        FULFILMENT_VERIFIED = "fulfilment_verified", "Fulfilment attested by verifier"
        FEEDBACK = "feedback", "Post-completion feedback"

    escrow = models.ForeignKey(Escrow, on_delete=models.PROTECT, related_name="reputation_events")
    participant = models.ForeignKey(Participant, on_delete=models.CASCADE, related_name="reputation_events")
    kind = models.CharField(max_length=24, choices=Kind.choices)

    rating = models.PositiveSmallIntegerField(null=True, blank=True, help_text="1-5, for feedback events")
    note = models.CharField(max_length=300, blank=True)

    on_chain_tx = models.CharField(max_length=80, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["escrow", "participant", "kind"],
                name="unique_reputation_event_per_escrow_kind",
                condition=models.Q(kind__in=["escrow_completed", "escrow_refunded", "fulfilment_verified"]),
            )
        ]

    def __str__(self) -> str:
        return f"{self.kind} — {self.participant.display_name}"
