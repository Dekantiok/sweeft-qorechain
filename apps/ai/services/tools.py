"""Sweeft AI tools — the only functions the model may call.

Every tool runs through the same Django business logic as the UI forms and
the APIs, and lands the same records. Tools NEVER sign or move money.
"""

from __future__ import annotations

import hashlib
import json
import logging
import time
from pathlib import Path

from django.conf import settings
from django.utils import timezone

logger = logging.getLogger(__name__)


def _participant(address: str):
    from apps.participants.models import Participant

    return (
        Participant.objects.filter(evm_address__iexact=address).first()
        or Participant.objects.filter(qor_address__iexact=address).first()
    )


def tool_search_listings(query: str = "", max_price_qor: float | None = None) -> dict:
    from apps.marketplace.models import Listing

    listings = Listing.objects.filter(status=Listing.Status.ACTIVE).select_related("seller")
    tokens = [t for t in str(query or "").lower().split() if len(t) > 2]
    if tokens:
        from django.db.models import Q

        cond = Q()
        for token in tokens:
            cond |= Q(title__icontains=token) | Q(description__icontains=token)
        listings = listings.filter(cond)
    results = []
    for listing in listings[:10]:
        price = float(listing.price_uqor) / 1e12
        if max_price_qor and price > max_price_qor:
            continue
        results.append(
            {
                "id": listing.on_chain_id,
                "title": listing.title,
                "description": listing.description[:140],
                "price_qor": round(price, 6),
                "quantity": listing.quantity,
                "seller": listing.seller.evm_address or "",
                "url": f"/marketplace/{listing.on_chain_id}/",
            }
        )
    return {"query": query, "count": len(results), "listings": results}


def tool_get_escrow_status(escrow_id: int) -> dict:
    from apps.blockchain.services.relayer import escrow_state

    try:
        state = escrow_state(int(escrow_id))
    except Exception as exc:
        return {"escrow_id": escrow_id, "error": str(exc)}
    return {
        "escrow_id": state["escrow_id"],
        "buyer": state["buyer"],
        "seller": state["seller"],
        "status": state["status"],  # 0 None, 1 Funded, 2 Completed, 3 Cancelled, 4 Refunded, 5 Disputed
        "delivered": state["delivered"],
        "confirmed": state["confirmed"],
        "attested": state["attested"],
        "release_eligible": state["release_eligible"],
        "refundable": state["refundable"],
    }


def tool_get_reputation(address: str) -> dict:
    participant = _participant(address)
    if not participant:
        return {"address": address, "error": "no Sweeft participant for this address yet"}
    profile = getattr(participant, "reputation", None)
    if not profile:
        return {"address": address, "trust_score": 0, "note": "no verified transactions yet"}
    return {
        "address": address,
        "trust_score": float(profile.trust_score),
        "completed": profile.successful_transactions,
        "total": profile.total_transactions,
        "verified_fulfilments": profile.verified_fulfilments,
    }


def tool_create_listing_draft(title: str, description: str = "", price_qor: float = 0, quantity: int = 1) -> dict:
    """Store metadata JSON + hash. Publishing stays a wallet action."""
    if price_qor <= 0:
        return {"error": "price_qor must be positive"}
    try:
        price_wei = int(round(float(price_qor) * 10**18))
    except (TypeError, ValueError):
        return {"error": "price_qor must be a number"}

    metadata = {
        "title": str(title)[:200],
        "description": str(description)[:4000],
        "sweeft_ai_draft": True,
        "created_at": int(time.time()),
    }
    raw = json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode()
    digest = hashlib.sha256(raw).hexdigest()
    directory = Path(settings.MEDIA_ROOT) / "listing-metadata"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{digest}.json").write_bytes(raw)
    return {
        "draft": True,
        "title": metadata["title"],
        "price_qor": price_qor,
        "price_wei": price_wei,
        "metadata_hash": "0x" + digest,
        "metadata_uri": f"{settings.MEDIA_URL}listing-metadata/{digest}.json",
        "next_step": "Publish it yourself at /marketplace/new/ — I'll pass the exact fields (the page re-hashes on publish).",
    }


def tool_create_escrow_draft(item: str, seller_hint: str = "", amount_qor: float = 0, delivery_days: float = 7) -> dict:
    """Draft escrow terms only. Creating/funding takes a wallet signature."""
    if amount_qor <= 0:
        return {"error": "amount_qor must be positive"}
    return {
        "draft": True,
        "item": item,
        "seller_hint": seller_hint,
        "amount_qor": amount_qor,
        "amount_wei": int(round(float(amount_qor) * 10**18)),
        "delivery_days": delivery_days,
        "terms_hash_hint": "hash of the exact strings below (for your records)",
        "next_step": "Pick a listing on the marketplace and press Buy — the terms are enforced by the contract, and release needs your QoreX signature.",
    }


def tool_check_mandate(action: str = "purchase", amount_qor: float = 0) -> dict:
    """Django-side policy check. The chain rule (authenticator) is the hard cap."""
    try:
        amount_uqor = int(float(amount_qor) * 1_000_000)
    except (TypeError, ValueError):
        amount_uqor = 0
    today_total = amount_uqor  # single-shot check: no history store in MVP
    return {
        "action": action,
        "amount_uqor": amount_uqor,
        "within_caps": True,
        "note": "Demo mandate (per-tx 5 QOR, daily 20 QOR). Raise limits only with a new owner-signed transaction.",
    }


TOOLS_REGISTRY = {
    "search_listings": tool_search_listings,
    "get_escrow_status": tool_get_escrow_status,
    "get_reputation": tool_get_reputation,
    "create_listing_draft": tool_create_listing_draft,
    "create_escrow_draft": tool_create_escrow_draft,
    "check_mandate": tool_check_mandate,
}


def execute_tool(name: str, **kwargs) -> dict:
    fn = TOOLS_REGISTRY.get(name)
    if not fn:
        return {"error": f"unknown tool {name}"}
    try:
        return fn(**kwargs)
    except Exception as exc:  # pragma: no cover
        logger.exception("tool %s failed", name)
        return {"error": str(exc)[:300]}
