"""Sweeft public API v1 — read-only, no auth, rate-limited.

Third parties and AI agents can inspect the whole system (marketplace,
escrow, disputes, proposals, board) without a wallet. Writes stay in the
wallet UI (or the session-gated internal endpoints), never here.

Units are explicit in every payload: `uqor` is the native token subunit
(1 QOR = 1e6 uqor) and `wei` is the EVM lane equivalent (1 QOR = 1e18 wei).
"""

from __future__ import annotations

import logging
import os

from django.http import JsonResponse
from django.views.decorators.http import require_GET

from config.ratelimit import is_rate_limited

logger = logging.getLogger(__name__)


def _limited(request) -> bool:
    # Per-endpoint bucket: browsing the API freely is fine, hammering one
    # endpoint is throttled (5s per IP per path).
    return is_rate_limited(f"api-v1:{request.path}", request, 5)


def _qor(uqor) -> str:
    return f"{int(uqor) / 1_000_000:.6f}".rstrip("0").rstrip(".") or "0"


def _paginate(request, items: list) -> JsonResponse:
    try:
        limit = min(int(request.GET.get("limit", 50)), 200)
        offset = max(int(request.GET.get("offset", 0)), 0)
    except ValueError:
        return JsonResponse({"error": "limit/offset must be integers"}, status=400)
    return JsonResponse(
        {"count": len(items), "limit": limit, "offset": offset, "results": items[offset : offset + limit]}
    )


@require_GET
def index(request):
    """API root: component index with entry points."""
    if _limited(request):
        return JsonResponse({"error": "slow down"}, status=429)
    base = request.build_absolute_uri("/api/v1/")
    return JsonResponse(
        {
            "name": "Sweeft API",
            "version": "1.0",
            "network": os.getenv("QORECHAIN_NETWORK", "testnet"),
            "contracts": {
                "vault": os.getenv("SWEEFT_VAULT_ADDRESS", ""),
                "marketplace": os.getenv("SWEEFT_MARKETPLACE_ADDRESS", ""),
                "oracle_registry": os.getenv("SWEEFT_ORACLE_REGISTRY_ADDRESS", ""),
                "dispute_board": os.getenv("SWEEFT_DISPUTE_BOARD_ADDRESS", ""),
                "dao": os.getenv("SWEEFT_DAO2_ADDRESS", ""),
            },
            "components": {
                "listings": base + "listings/",
                "escrows": base + "escrows/",
                "disputes": base + "disputes/",
                "proposals": base + "proposals/",
                "board": base + "board/",
                "verifiers": base + "verifiers/",
            },
            "notes": "Read-only. Units: uqor (native) and wei (EVM lane). Writes (buy, fund, release) happen in the wallet UI.",
        }
    )


@require_GET
def listings(request):
    if _limited(request):
        return JsonResponse({"error": "slow down"}, status=429)
    from apps.marketplace.models import Listing

    qs = Listing.objects.select_related("seller").order_by("-created_at")
    status = request.GET.get("status")
    if status:
        qs = qs.filter(status=status)
    items = [
        {
            "on_chain_id": l.on_chain_id,
            "title": l.title,
            "status": l.status,
            "price_uqor": str(l.price_uqor),
            "price_qor": _qor(l.price_uqor),
            "quantity": l.quantity,
            "seller": l.seller.evm_address,
            "metadata_uri": l.metadata_uri,
            "metadata_hash": l.metadata_hash,
        }
        for l in qs[:500]
    ]
    return _paginate(request, items)


@require_GET
def listing_detail(request, on_chain_id: int):
    if _limited(request):
        return JsonResponse({"error": "slow down"}, status=429)
    from apps.marketplace.models import Listing

    l = Listing.objects.filter(on_chain_id=on_chain_id).select_related("seller").first()
    if not l:
        return JsonResponse({"error": "listing not found"}, status=404)
    return JsonResponse(
        {
            "on_chain_id": l.on_chain_id,
            "title": l.title,
            "description": l.description,
            "status": l.status,
            "price_uqor": str(l.price_uqor),
            "price_qor": _qor(l.price_uqor),
            "quantity": l.quantity,
            "seller": l.seller.evm_address,
            "metadata_uri": l.metadata_uri,
            "metadata_hash": l.metadata_hash,
            "page": f"/marketplace/{l.on_chain_id}/",
        }
    )


@require_GET
def escrows(request):
    if _limited(request):
        return JsonResponse({"error": "slow down"}, status=429)
    from apps.escrow.models import Escrow

    qs = Escrow.objects.select_related("buyer", "seller").order_by("-created_at")
    for param, field in (("buyer", "buyer__evm_address"), ("seller", "seller__evm_address"), ("state", "state")):
        value = request.GET.get(param)
        if value:
            qs = qs.filter(**{field: value})
    items = [
        {
            "on_chain_id": e.on_chain_id,
            "state": e.state,
            "buyer": e.buyer.evm_address,
            "seller": e.seller.evm_address,
            "amount_uqor": str(e.amount_uqor),
            "amount_qor": _qor(e.amount_uqor),
            "delivery_deadline": e.delivery_deadline.isoformat(),
            "pqc_nonce": e.pqc_nonce,
            "page": f"/escrow/{e.on_chain_id}/",
        }
        for e in qs[:500]
    ]
    return _paginate(request, items)


@require_GET
def escrow_detail(request, on_chain_id: int):
    if _limited(request):
        return JsonResponse({"error": "slow down"}, status=429)
    from apps.blockchain.services.relayer import escrow_state
    from apps.escrow.models import Escrow

    e = Escrow.objects.filter(on_chain_id=on_chain_id).select_related("buyer", "seller").first()
    if not e:
        return JsonResponse({"error": "escrow not found"}, status=404)
    live = None
    try:
        live = escrow_state(on_chain_id)
    except Exception:
        logger.exception("live escrow read failed for %s", on_chain_id)
    return JsonResponse(
        {
            "on_chain_id": e.on_chain_id,
            "state": e.state,
            "buyer": e.buyer.evm_address,
            "seller": e.seller.evm_address,
            "amount_uqor": str(e.amount_uqor),
            "amount_qor": _qor(e.amount_uqor),
            "delivery_deadline": e.delivery_deadline.isoformat(),
            "pqc_nonce": e.pqc_nonce,
            "live": live,
            "page": f"/escrow/{e.on_chain_id}/",
            "proof": f"/proof/escrow/{e.on_chain_id}/",
        }
    )


@require_GET
def disputes(request):
    if _limited(request):
        return JsonResponse({"error": "slow down"}, status=429)
    from apps.governance.models import Dispute

    qs = Dispute.objects.select_related("escrow", "raiser").order_by("-created_at")
    state = request.GET.get("state")
    if state:
        qs = qs.filter(state=state)
    items = [
        {
            "on_chain_id": d.on_chain_id,
            "state": d.state,
            "escrow_id": d.escrow.on_chain_id,
            "raiser": d.raiser.evm_address,
            "release_to_seller": d.release_to_seller,
            "votes_for_release": d.votes_for_release,
            "votes_for_refund": d.votes_for_refund,
            "appeal_votes_for_release": d.appeal_votes_for_release,
            "appeal_votes_for_refund": d.appeal_votes_for_refund,
            "page": "/disputes/",
        }
        for d in qs[:500]
    ]
    return _paginate(request, items)


@require_GET
def dispute_detail(request, on_chain_id: int):
    if _limited(request):
        return JsonResponse({"error": "slow down"}, status=429)
    from apps.governance.models import Dispute

    d = (
        Dispute.objects.filter(on_chain_id=on_chain_id)
        .select_related("escrow", "raiser")
        .prefetch_related("members__participant")
        .first()
    )
    if not d:
        return JsonResponse({"error": "dispute not found"}, status=404)
    return JsonResponse(
        {
            "on_chain_id": d.on_chain_id,
            "state": d.state,
            "escrow_id": d.escrow.on_chain_id,
            "raiser": d.raiser.evm_address,
            "release_to_seller": d.release_to_seller,
            "panel": [
                {
                    "address": m.participant.evm_address,
                    "round": 2 if m.position >= 10 else 1,
                    "vote_release": m.vote_release,
                    "claimed": m.claimed,
                }
                for m in d.members.all()
            ],
            "page": "/disputes/",
        }
    )


@require_GET
def proposals(request):
    if _limited(request):
        return JsonResponse({"error": "slow down"}, status=429)
    from apps.governance.models import Proposal

    qs = Proposal.objects.select_related("proposer").order_by("-created_at")
    state = request.GET.get("state")
    if state:
        qs = qs.filter(state=state)
    items = [
        {
            "on_chain_id": p.on_chain_id,
            "kind": p.kind,
            "title": p.title,
            "state": p.state,
            "proposer": p.proposer.evm_address,
            "votes_for": p.votes_for,
            "votes_against": p.votes_against,
            "execution_tx": p.execution_tx,
            "page": "/governance/",
        }
        for p in qs[:500]
    ]
    return _paginate(request, items)


@require_GET
def board(request):
    """Live dispute-board parameters + pool (chain read, cached 30s)."""
    if _limited(request):
        return JsonResponse({"error": "slow down"}, status=429)
    from apps.blockchain.services.relayer import board_state

    try:
        state = board_state()
    except Exception as exc:
        return JsonResponse({"error": str(exc)[:200]}, status=502)
    return JsonResponse(
        {
            "address": state["address"],
            "min_stake_qor": state["min_stake_wei"] / 10**18,
            "reward_pool_qor": state["reward_pool_wei"] / 10**18,
            "pool_size": state["pool_size"],
            "join_window_seconds": state["join_window"],
            "voting_period_seconds": state["voting_period"],
            "appeal_window_seconds": state["appeal_window"],
            "unstake_cooldown_seconds": state["unstake_cooldown"],
            "dispute_count": state["dispute_count"],
        }
    )


@require_GET
def verifiers(request):
    """Verifiers that have attested evidence, from the indexed record."""
    if _limited(request):
        return JsonResponse({"error": "slow down"}, status=429)
    from apps.oracle.models import FulfilmentEvidence
    from apps.participants.models import Participant

    attesting = set(
        FulfilmentEvidence.objects.values_list("submitted_by__evm_address", flat=True)
    )
    items = []
    for participant in Participant.objects.filter(evm_address__in=attesting).order_by("evm_address")[:500]:
        profile = getattr(participant, "reputation", None)
        items.append(
            {
                "address": participant.evm_address,
                "trust_score": float(profile.trust_score) if profile else 0,
                "completed": profile.successful_transactions if profile else 0,
            }
        )
    return _paginate(request, items)
