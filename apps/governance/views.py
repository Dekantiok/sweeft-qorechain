"""Governance views — proposals and the dispute board."""

from __future__ import annotations

import logging
import os

from django.shortcuts import render

from .models import Dispute, Proposal

logger = logging.getLogger(__name__)


def proposal_list(request):
    proposals = Proposal.objects.select_related("proposer", "target_verifier").order_by("-created_at")
    return render(request, "governance/index.html", {"proposals": proposals})


def dispute_list(request):
    disputes = (
        Dispute.objects.select_related("escrow", "raiser")
        .prefetch_related("members__participant")
        .order_by("-created_at")[:50]
    )

    board_state = None
    try:
        from apps.blockchain.services.relayer import board_state as read_board_state

        board_state = read_board_state()
    except Exception:
        logger.exception("could not read dispute board state")

    return render(
        request,
        "governance/disputes.html",
        {
            "disputes": disputes,
            "board_state": board_state,
            "board_address": os.getenv("SWEEFT_DISPUTE_BOARD_ADDRESS", ""),
        },
    )
