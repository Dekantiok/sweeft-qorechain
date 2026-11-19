"""Governance views — proposals and their on-chain execution status."""

from __future__ import annotations

from django.shortcuts import render

from .models import Proposal


def proposal_list(request):
    proposals = Proposal.objects.select_related("proposer", "target_verifier").order_by("-created_at")
    return render(request, "governance/index.html", {"proposals": proposals})
