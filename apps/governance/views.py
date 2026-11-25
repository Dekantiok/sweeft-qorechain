"""Governance views — proposals and the dispute board."""

from __future__ import annotations

import logging
import os

from django.shortcuts import render

from .models import Dispute, Proposal

logger = logging.getLogger(__name__)


def proposal_list(request):
    proposals = Proposal.objects.select_related("proposer", "target_verifier").order_by("-created_at")
    return render(
        request,
        "governance/index.html",
        {"proposals": proposals, "dao_address": os.getenv("SWEEFT_DAO2_ADDRESS", "")},
    )


def dispute_list(request):
    disputes = list(
        Dispute.objects.select_related("escrow", "raiser")
        .prefetch_related("members__participant")
        .order_by("-created_at")[:50]
    )

    # The v6 board takes the raiser bond (1% of escrow, 0.1 QOR floor) and a
    # 2x appeal bond. Compute both from the escrow amount for the UI.
    for dispute in disputes:
        amount_wei = int(dispute.escrow.amount_uqor or 0) * 10**12
        dispute.dispute_bond_wei = max(10**17, amount_wei // 100)
        dispute.appeal_bond_wei = dispute.dispute_bond_wei * 2
        dispute.dispute_bond_qor = dispute.dispute_bond_wei / 10**18
        dispute.appeal_bond_qor = dispute.appeal_bond_wei / 10**18
        dispute.first_panel = [m for m in dispute.members.all() if m.position < 10]
        dispute.appeal_panel = [m for m in dispute.members.all() if m.position >= 10]

    board_state = None
    try:
        from apps.blockchain.services.relayer import board_state as read_board_state

        board_state = read_board_state()
        board_state["min_stake_qor"] = board_state["min_stake_wei"] / 10**18
        board_state["reward_pool_qor"] = board_state["reward_pool_wei"] / 10**18
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
