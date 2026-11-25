"""Governance — Sweeft-specific proposals.

Stake-weighted voting. The MVP's executable power: oracle verifier approval
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
        FEE_POLICY = "fee_policy", "Application fee policy"
        CRED_PARAMETERS = "cred_parameters", "Reputation parameters"
        TREASURY = "treasury", "Treasury allocation"
        OTHER = "other", "Governance action"

    class State(models.TextChoices):
        OPEN = "open", "Open"
        PASSED = "passed", "Passed"
        EXECUTED = "executed", "Executed"
        REJECTED = "rejected", "Rejected"
        CANCELLED = "cancelled", "Cancelled"
        EXPIRED = "expired", "Expired"
        FAILED = "failed", "Failed"
        VETOED = "vetoed", "Vetoed"

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


class Dispute(models.Model):
    """A staked-resolver dispute over a frozen escrow (SweeftDisputeBoard)."""

    class State(models.TextChoices):
        OPEN = "open", "Open"  # first panel voting
        RESOLVED = "resolved", "Decision pending appeal"
        APPEALED = "appealed", "Appealed"
        FINAL = "final", "Final"

    on_chain_id = models.PositiveBigIntegerField(unique=True)
    escrow = models.ForeignKey("escrow.Escrow", on_delete=models.PROTECT, related_name="disputes")
    raiser = models.ForeignKey(Participant, on_delete=models.PROTECT, related_name="disputes_raised")

    state = models.CharField(max_length=16, choices=State.choices, default=State.OPEN)
    release_to_seller = models.BooleanField(null=True, blank=True)
    panel_selected = models.BooleanField(default=False)

    votes_for_release = models.PositiveSmallIntegerField(default=0)
    votes_for_refund = models.PositiveSmallIntegerField(default=0)
    appeal_votes_for_release = models.PositiveSmallIntegerField(default=0)
    appeal_votes_for_refund = models.PositiveSmallIntegerField(default=0)

    appeal_bond_wei = models.BigIntegerField(default=0)
    appeal_ends_at = models.DateTimeField(null=True, blank=True)
    appeal_voting_ends_at = models.DateTimeField(null=True, blank=True)

    opened_tx = models.CharField(max_length=80, blank=True)
    settled_tx = models.CharField(max_length=80, blank=True)
    joining_ends_at = models.DateTimeField(null=True, blank=True)
    voting_ends_at = models.DateTimeField(null=True, blank=True)
    decision_tx = models.CharField(max_length=80, blank=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"Dispute #{self.on_chain_id} (escrow {self.escrow_id}, {self.state})"


class DisputeMember(models.Model):
    dispute = models.ForeignKey(Dispute, on_delete=models.CASCADE, related_name="members")
    participant = models.ForeignKey(Participant, on_delete=models.PROTECT, related_name="dispute_memberships")
    position = models.PositiveSmallIntegerField()
    vote_release = models.BooleanField(null=True, blank=True)
    claimed = models.BooleanField(default=False)

    @property
    def panel(self) -> str:
        return "appeal" if self.position >= 10 else "first"

    claimed_uqor = models.DecimalField(max_digits=30, decimal_places=0, default=0)
    joined_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["dispute", "participant"], name="one_membership_per_dispute")
        ]
        ordering = ["position"]


class ResolverProfile(models.Model):
    """Staking status of a dispute resolver, refreshed from chain events."""

    participant = models.OneToOneField(Participant, on_delete=models.CASCADE, related_name="resolver_profile")
    staked_uqor = models.DecimalField(max_digits=30, decimal_places=0, default=0)
    active_boards = models.PositiveSmallIntegerField(default=0)
    rewards_claimed_uqor = models.DecimalField(max_digits=30, decimal_places=0, default=0)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"Resolver {self.participant.display_name}: {self.staked_uqor}"
