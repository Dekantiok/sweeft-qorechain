"""Marketplace views — discovery over the indexed on-chain listings."""

from __future__ import annotations

import hashlib
import json
import logging
import time
from pathlib import Path

from django.conf import settings
from django.db.models import Q
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, render
from django.views.decorators.http import require_POST

from .models import Category, Listing

logger = logging.getLogger(__name__)


def home(request):
    """Landing page: live strip is indexed data only (chain reads are cached)."""
    from django.db.models import Sum

    from apps.escrow.models import Escrow

    recent = Listing.objects.filter(status=Listing.Status.ACTIVE).select_related("seller", "category")[:6]
    completed = Escrow.objects.filter(state=Escrow.State.COMPLETED)
    released = completed.aggregate(total=Sum("amount_uqor"))["total"] or 0

    from apps.ai.views import assistant_context

    context = {
        "recent_listings": recent,
        "wallet_attached": bool(request.session.get("wallet_account")),
        "stats": {
            "listings_live": Listing.objects.filter(status=Listing.Status.ACTIVE).count(),
            "escrows_settled": completed.count(),
            "released_qor": f"{int(released) / 1_000_000:.4f}".rstrip("0").rstrip("."),
        },
    }
    context.update(assistant_context(request))
    return render(request, "marketplace/home.html", context)


def listing_list(request):
    listings = Listing.objects.select_related("seller", "category")

    query = request.GET.get("q", "").strip()
    category = request.GET.get("category", "").strip()
    status = request.GET.get("status", "active").strip()

    if query:
        listings = listings.filter(Q(title__icontains=query) | Q(description__icontains=query))
    if category:
        listings = listings.filter(category__slug=category)
    if status and status != "all":
        listings = listings.filter(status=status)

    return render(
        request,
        "marketplace/list.html",
        {
            "listings": listings,
            "categories": Category.objects.all(),
            "query": query,
            "active_category": category,
            "active_status": status,
        },
    )


def listing_detail(request, listing_id: int):
    listing = get_object_or_404(
        Listing.objects.select_related("seller", "category"), on_chain_id=listing_id
    )
    import os

    wallet = request.session.get("wallet_account")
    is_seller = bool(wallet and listing.seller and wallet.lower() == (listing.seller.evm_address or "").lower())
    return render(
        request,
        "marketplace/detail.html",
        {
            "listing": listing,
            "marketplace_address": os.getenv("SWEEFT_MARKETPLACE_ADDRESS", ""),
            "is_seller": is_seller,
        },
    )


def listing_new(request):
    """Seller form: metadata is stored hash-anchored, then published on-chain."""
    import os

    demo_carrier_address = ""
    try:
        from apps.logistics.carriers import demo_carrier_keypair

        _, _, demo_carrier_address = demo_carrier_keypair()
    except Exception:
        pass

    return render(
        request,
        "marketplace/new.html",
        {
            "marketplace_address": os.getenv("SWEEFT_MARKETPLACE_ADDRESS", ""),
            "demo_carrier_address": demo_carrier_address,
        },
    )


@require_POST
def api_metadata(request):
    """Store listing metadata JSON; return the URI and the SHA-256 the chain will carry.

    The hash is computed over the exact stored bytes, so a buyer can fetch the
    file and verify it against the on-chain hash.
    """
    try:
        payload = json.loads(request.body or b"{}")
    except json.JSONDecodeError:
        return JsonResponse({"error": "invalid JSON body"}, status=400)

    # Require a connected wallet; the seller identity comes from the session,
    # never from client-supplied JSON.
    wallet = (request.session.get("wallet_account") or {}).get("evm", "").lower()
    if not wallet:
        return JsonResponse({"error": "connect your wallet first"}, status=401)

    title = str(payload.get("title", "")).strip()
    if not title:
        return JsonResponse({"error": "title is required"}, status=400)

    metadata = {
        "title": title[:200],
        "description": str(payload.get("description", ""))[:4000],
        "category": str(payload.get("category", "")).strip()[:80],
        "seller_evm": wallet,
        "created_at": int(time.time()),
        "sweeft_metadata_version": 1,
    }

    raw = json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode()
    digest = hashlib.sha256(raw).hexdigest()

    directory = Path(settings.MEDIA_ROOT) / "listing-metadata"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{digest}.json").write_bytes(raw)

    uri = request.build_absolute_uri(f"{settings.MEDIA_URL}listing-metadata/{digest}.json")
    return JsonResponse({"uri": uri, "hash": "0x" + digest, "metadata": metadata})
