"""Sweeft AI — conversations, mandates, and the agent action log.

The AI is a commerce assistant and, under an explicit mandate, a delegated
buyer. It never signs transactions: the mandate bounds what Django may ask the
user's agent key to execute, and the chain itself enforces the spending rule
registered by the owner.
"""

from __future__ import annotations

from django.db import models

from apps.participants.models import Participant


class Conversation(models.Model):
    participant = models.ForeignKey(Participant, on_delete=models.CASCADE, related_name="conversations")
    title = models.CharField(max_length=200, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-updated_at"]

    def __str__(self) -> str:
        return self.title or f"Conversation #{self.pk}"


class Message(models.Model):
    class Role(models.TextChoices):
        USER = "user", "User"
        ASSISTANT = "assistant", "Assistant"
        TOOL = "tool", "Tool result"
        SYSTEM = "system", "System"

    conversation = models.ForeignKey(Conversation, on_delete=models.CASCADE, related_name="messages")
    role = models.CharField(max_length=16, choices=Role.choices)
    content = models.TextField()
    tool_name = models.CharField(max_length=80, blank=True)
    tool_payload = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["created_at"]

    def __str__(self) -> str:
        return f"[{self.role}] {self.content[:60]}"


class Mandate(models.Model):
    """An owner-granted, bounded authorization for autonomous buying.

    Mirrors the on-chain authenticator spending rule. The chain enforces the
    hard cap; Django enforces the softer policy (categories, trust thresholds).
    Raising limits requires a new owner-signed transaction.
    """

    class State(models.TextChoices):
        DRAFT = "draft", "Draft"
        ACTIVE = "active", "Active"
        PAUSED = "paused", "Paused"
        EXPIRED = "expired", "Expired"
        REVOKED = "revoked", "Revoked"

    owner = models.ForeignKey(Participant, on_delete=models.CASCADE, related_name="mandates")
    agent_label = models.CharField(max_length=80, default="sweeft-buyer")

    # On-chain authenticator binding
    agent_pubkey = models.CharField(max_length=128, blank=True, help_text="Agent ed25519 public key (hex)")
    link_tx = models.CharField(max_length=80, blank=True)

    # Spending policy — mirrors the on-chain rule (uqor)
    per_tx_limit_uqor = models.DecimalField(max_digits=30, decimal_places=0)
    daily_limit_uqor = models.DecimalField(max_digits=30, decimal_places=0)
    # Autopilot is opt-in per mandate: the AI may execute pre-signed
    # releases only when the owner explicitly allowed autonomous execution.
    autopilot_allowed = models.BooleanField(default=False)

    # Django-side policy
    allowed_categories = models.ManyToManyField("marketplace.Category", blank=True)
    min_seller_trust_score = models.DecimalField(max_digits=5, decimal_places=2, default=0)
    auto_execute = models.BooleanField(
        default=False, help_text="When false, the agent prepares and asks for confirmation"
    )

    state = models.CharField(max_length=16, choices=State.choices, default=State.DRAFT)
    expires_at = models.DateTimeField()

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]

    @property
    def per_tx_qor(self):
        return int(self.per_tx_limit_uqor) / 1_000_000

    @property
    def daily_qor(self):
        return int(self.daily_limit_uqor) / 1_000_000

    def __str__(self) -> str:
        return f"Mandate for {self.owner.display_name} ({self.state})"


class SellerAgentMandate(models.Model):
    """Seller-granted, bounded authorization for autonomous negotiation.

    Floor/target are private to the seller and must never be returned to
    buyers. The agent evaluates offers deterministically against them
    (see services/seller_agent.py) and the buyer wallet still signs any
    purchase — the mandate never moves money.
    """

    class State(models.TextChoices):
        ACTIVE = "active", "Active"
        PAUSED = "paused", "Paused"
        REVOKED = "revoked", "Revoked"
        EXPIRED = "expired", "Expired"

    class Strategy(models.TextChoices):
        BALANCED = "balanced", "Balanced"
        FIRM = "firm", "Firm"
        FLEXIBLE = "flexible", "Flexible"

    listing = models.ForeignKey(
        "marketplace.Listing", on_delete=models.CASCADE, related_name="seller_mandates"
    )
    seller = models.ForeignKey(
        Participant, on_delete=models.CASCADE, related_name="seller_mandates"
    )
    # Private negotiation bounds in uqor (1 QOR = 10^6 uqor). Never returned.
    floor_uqor = models.DecimalField(max_digits=30, decimal_places=0)
    target_uqor = models.DecimalField(max_digits=30, decimal_places=0)
    strategy = models.CharField(
        max_length=16, choices=Strategy.choices, default=Strategy.BALANCED
    )
    max_rounds = models.PositiveSmallIntegerField(default=5)
    auto_accept = models.BooleanField(default=False)
    state = models.CharField(max_length=16, choices=State.choices, default=State.ACTIVE)
    expires_at = models.DateTimeField()
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["listing", "state"]),
            models.Index(fields=["seller", "state"]),
        ]

    def __str__(self) -> str:
        return f"SellerAgentMandate listing={self.listing_id} seller={self.seller_id} ({self.state})"


class AgentAction(models.Model):
    """Audit log of every autonomous action the agent took or attempted."""

    class Outcome(models.TextChoices):
        PLANNED = "planned", "Planned"
        REFUSED_POLICY = "refused_policy", "Refused by Django policy"
        REFUSED_CHAIN = "refused_chain", "Refused by chain rule"
        EXECUTED = "executed", "Executed"
        FAILED = "failed", "Failed"

    mandate = models.ForeignKey(Mandate, on_delete=models.PROTECT, related_name="actions")
    action = models.CharField(max_length=80)
    payload = models.JSONField(default=dict, blank=True)
    outcome = models.CharField(max_length=20, choices=Outcome.choices)
    detail = models.CharField(max_length=500, blank=True)
    tx_hash = models.CharField(max_length=80, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.action} -> {self.outcome}"
