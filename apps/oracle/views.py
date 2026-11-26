"""Oracle views — fulfilment evidence review for authorized verifiers."""

from __future__ import annotations

import logging

from django.shortcuts import render

from apps.blockchain.services.reads import is_verifier

from .models import FulfilmentEvidence

logger = logging.getLogger(__name__)

# Indexed (DB) escrow state -> on-chain status int (0 None, 1 Funded,
# 2 Completed, 3 Cancelled, 4 Refunded, 5 Disputed). B-12: the page used to
# do one live chain read per evidence row (N reads, 30s+); it now uses the
# indexed mirror, which the indexer keeps in sync.
_DB_TO_CHAIN_STATUS = {
    "created": 0,
    "funded": 1,
    "fulfilled": 1,
    "delivered": 1,
    "release_eligible": 1,
    "completed": 2,
    "cancelled": 3,
    "refunded": 4,
    "disputed": 5,
}


def evidence_list(request):
    evidence = FulfilmentEvidence.objects.select_related(
        "escrow", "escrow__buyer", "escrow__seller", "submitted_by"
    ).order_by("-submitted_at")[:50]

    wallet = (request.session.get("wallet_account") or {}).get("evm", "")
    verifier = is_verifier(wallet) if wallet else False

    import os

    rows = [
        {
            "evidence": item,
            "state": {"status": _DB_TO_CHAIN_STATUS.get(item.escrow.state, 0)},
        }
        for item in evidence
    ]

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
