"""Oracle views — fulfilment evidence review for authorized verifiers."""

from __future__ import annotations

from django.shortcuts import render

from .models import FulfilmentEvidence


def evidence_list(request):
    evidence = FulfilmentEvidence.objects.select_related(
        "escrow", "escrow__buyer", "escrow__seller", "submitted_by"
    ).order_by("-submitted_at")
    return render(request, "oracle/index.html", {"evidence": evidence})
