"""Oracle views — fulfilment evidence review for authorized verifiers."""

from __future__ import annotations

import logging

from django.shortcuts import render

from apps.blockchain.services.relayer import escrow_state, is_verifier

from .models import FulfilmentEvidence

logger = logging.getLogger(__name__)


def evidence_list(request):
    evidence = FulfilmentEvidence.objects.select_related(
        "escrow", "escrow__buyer", "escrow__seller", "submitted_by"
    ).order_by("-submitted_at")

    wallet = (request.session.get("wallet_account") or {}).get("evm", "")
    verifier = is_verifier(wallet) if wallet else False

    import os

    rows = []
    for item in evidence:
        state = None
        try:
            state = escrow_state(item.escrow.on_chain_id)
        except Exception:
            logger.exception("could not read escrow state for evidence %s", item.pk)
        rows.append({"evidence": item, "state": state})

    return render(
        request,
        "oracle/index.html",
        {
            "rows": rows,
            "wallet_attached": bool(wallet),
            "is_verifier": verifier,
            "vault_address": os.getenv("SWEEFT_VAULT_ADDRESS", ""),
        },
    )
