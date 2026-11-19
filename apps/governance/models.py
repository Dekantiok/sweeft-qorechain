"""Governance — Sweeft-specific proposals.

One wallet, one vote. The MVP's executable power: oracle verifier approval
(executed on-chain against SweeftOracleRegistry). All other proposal types are
recorded and read by Django as parameters.
"""

from __future__ import annotations

from django.db import models

from apps.participants.models import Participant


class Proposal(models.Model):
    class Kind(models.TextChoices):
        VERIFIER_APPROVAL = "verifier_approval", "Approve oracle verifier"
        VERIFIER_REMOVAL = "verifier_removal", "Remove oracle verifier"
        FEE_POLICY = "fee_policy", "Application fee policy (recorded)"
        CRED_PARAMETERS = "cred_parameters", "Reputation parameters (recorded)"
        TREASURY = "treasury", "Treasury allocation (recorded)"

    class State(models.TextChoices):
        OPEN = "open", "Open"
        PASSED = "passed", "Passed"
        EXECUTED = "executed", "Executed"
        REJECTED = "rejected", "Rejected"
        CANCELLED = "cancelled", "Cancelled"

    on_chain_id = models.PositiveBigIntegerField(unique=True, null=True, blank=True)
    proposer = models.ForeignKey(Participant, on_delete=models.PROTECT, related_name="proposals")

    kind = models.CharField(max_length=32, choices=Kind.choices)
    title = models.CharField(max_length=200)
    description = models.TextField()

    # Verifier proposals
    target_verifier = models.ForeignKey(
        Participant, on_delete=models.PROTECT, null=True, blank=True, related_name="verifier_proposals"
    )

    # Recorded-parameter proposals
    payload = models.JSONField(default=dict, blank=True)

    state = models.CharField(max_length=16, choices=State.choices, default=State.OPEN)
    voting_ends_at = models.DateTimeField()

    execution_tx = models.CharField(max_length=80, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"Proposal #{self.pk} [{self.state}] {self.title}"

    @property
    def votes_for(self) -> int:
        return self.votes.filter(choice=Vote.Choice.FOR).count()

    @property
    def votes_against(self) -> int:
        return self.votes.filter(choice=Vote.Choice.AGAINST).count()


class Vote(models.Model):
    class Choice(models.TextChoices):
        FOR = "for", "For"
        AGAINST = "against", "Against"
        ABSTAIN = "abstain", "Abstain"

    proposal = models.ForeignKey(Proposal, on_delete=models.CASCADE, related_name="votes")
    voter = models.ForeignKey(Participant, on_delete=models.PROTECT, related_name="votes")
    choice = models.CharField(max_length=8, choices=Choice.choices)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["proposal", "voter"], name="one_vote_per_participant")
        ]
