"""Oracle — fulfilment evidence and verification.

AI may assist in assessing evidence, but AI conclusions are never trusted
attestations. Only authorized verifiers (governed by the DAO) attest, and the
attestation is recorded on-chain in SweeftOracleRegistry.
"""

from __future__ import annotations

from django.db import models

from apps.escrow.models import Escrow
from apps.participants.models import Participant


class FulfilmentEvidence(models.Model):
    class EvidenceType(models.TextChoices):
        DELIVERY_PHOTO = "delivery_photo", "Delivery photo"
        CARRIER_RECEIPT = "carrier_receipt", "Carrier receipt"
        SIGNATURE = "signature", "Recipient signature"
        SELLER_STATEMENT = "seller_statement", "Seller statement"
        LOGISTICS_API = "logistics_api", "Logistics provider confirmation"
        OTHER = "other", "Other"

    class Status(models.TextChoices):
        SUBMITTED = "submitted", "Submitted"
        VERIFIED = "verified", "Verified"
        REJECTED = "rejected", "Rejected"
        NEEDS_INFO = "needs_info", "Needs more information"

    escrow = models.ForeignKey(Escrow, on_delete=models.CASCADE, related_name="evidence")
    submitted_by = models.ForeignKey(Participant, on_delete=models.PROTECT, related_name="evidence_submitted")

    evidence_type = models.CharField(max_length=24, choices=EvidenceType.choices)
    evidence_reference = models.CharField(
        max_length=500, help_text="URL or storage reference — files are never stored on-chain"
    )
    content_hash = models.CharField(
        max_length=66, blank=True, help_text="SHA-256 of the evidence file/record for on-chain anchoring"
    )
    description = models.TextField(blank=True)

    verification_status = models.CharField(max_length=16, choices=Status.choices, default=Status.SUBMITTED)
    verified_by = models.ForeignKey(
        Participant, on_delete=models.SET_NULL, null=True, blank=True, related_name="evidence_verified"
    )
    verification_notes = models.TextField(blank=True)
    verified_at = models.DateTimeField(null=True, blank=True)

    # On-chain anchoring (attestation or rejection tx)
    attestation_tx = models.CharField(max_length=80, blank=True)

    submitted_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-submitted_at"]
        verbose_name_plural = "fulfilment evidence"

    def __str__(self) -> str:
        return f"Evidence #{self.pk} for escrow {self.escrow_id} ({self.verification_status})"
