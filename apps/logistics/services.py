"""Shared logistics services used by views and the relayer."""

from __future__ import annotations

from django.utils import timezone

from apps.escrow.models import Escrow

from .models import VerificationRequest


def sync_verification_from_chain(escrow: Escrow) -> VerificationRequest | None:
    """Re-read the latest verification record for an escrow (idempotent).

    Kept for the verifier-attestation flow: the contract records one attestation
    per escrow; the latest VerificationRequest mirrors it.
    """
    vr = VerificationRequest.objects.filter(escrow=escrow).order_by("-created_at").first()
    if not vr:
        return None
    if escrow.state == Escrow.State.COMPLETED:
        next_status = "VERIFIED"
    elif escrow.state == Escrow.State.REFUNDED:
        next_status = "FAILED"
    else:
        next_status = "PENDING"

    if vr.status != next_status:
        vr.status = next_status
        if next_status == "VERIFIED":
            vr.completed_at = timezone.now()
        vr.save(update_fields=["status", "completed_at"])
    return vr
