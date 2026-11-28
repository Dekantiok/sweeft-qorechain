"""Seller-agent negotiation — deterministic evaluation of offers against a
private SellerAgentMandate.

Floor/target values are private to the seller and must never be returned
to buyers. evaluate_offer returns only accept/counter/reject plus a
banded counter and a coarse distance bucket.
"""

from __future__ import annotations

import statistics

from django.utils import timezone

_COUNTER_BAND_UQOR = 50_000  # 0.05 QOR band, mirrors existing negotiation banding


def _active_mandate(listing):
    from apps.ai.models import SellerAgentMandate

    return (
        SellerAgentMandate.objects.filter(
            listing=listing,
            seller=listing.seller,
            state=SellerAgentMandate.State.ACTIVE,
        )
        .order_by("-created_at")
        .first()
    )


def _is_expired(mandate) -> bool:
    return bool(mandate and mandate.expires_at and mandate.expires_at < timezone.now())


def _band_counter(counter: int) -> int:
    return -(-int(counter) // _COUNTER_BAND_UQOR) * _COUNTER_BAND_UQOR


def _distance_bucket(floor: int, offered: int) -> str:
    if floor > 0:
        distance = floor - offered
        if distance <= floor // 10:
            return "close"
        if distance <= floor // 5:
            return "near"
        if distance <= floor // 2:
            return "far"
    return "very_far"


def evaluate_offer(listing, offered_uqor: int, rounds_used: int = 0) -> dict:
    """Evaluate an offer against the listing's active SellerAgentMandate.

    Deterministic. Returns one of:
      accepted  — offered >= target
      countered — floor <= offered < target, counter = midpoint banded
      rejected  — offered < floor (distance bucket, no floor leak),
                  round limit exceeded, or no active mandate.

    The returned dict NEVER contains floor/target values.
    ``counter_uqor`` is the exact internal counter (for Negotiation
    records); ``counter_qor`` is the banded, buyer-safe value.
    """
    try:
        offered = int(offered_uqor)
    except (TypeError, ValueError):
        return {
            "status": "rejected",
            "reason": "invalid_offer",
            "auto_accept": False,
            "active": False,
            "rounds_used": int(rounds_used or 0),
        }

    rounds_used = int(rounds_used or 0)
    mandate = _active_mandate(listing)

    if mandate is None:
        return {
            "status": "rejected",
            "reason": "no_active_mandate",
            "auto_accept": False,
            "active": False,
            "rounds_used": rounds_used,
        }
    if _is_expired(mandate):
        return {
            "status": "rejected",
            "reason": "mandate_expired",
            "auto_accept": False,
            "active": False,
            "rounds_used": rounds_used,
            "max_rounds": int(mandate.max_rounds or 5),
        }
    max_rounds = int(mandate.max_rounds or 5)
    if rounds_used >= max_rounds and max_rounds > 0:
        return {
            "status": "rejected",
            "reason": "round_limit_exceeded",
            "auto_accept": False,
            "active": True,
            "rounds_used": rounds_used,
            "max_rounds": max_rounds,
        }

    floor = int(mandate.floor_uqor or 0)
    target = int(mandate.target_uqor or floor or 0)
    # Fall back to the listing floor when the mandate omits a target.
    if not floor:
        floor = int(listing.floor_price_uqor or 0)
    if not target or target < floor:
        target = floor

    if target and offered >= target:
        return {
            "status": "accepted",
            "reason": "at_or_above_target",
            "auto_accept": bool(mandate.auto_accept),
            "active": True,
            "rounds_used": rounds_used,
            "max_rounds": max_rounds,
            "offered_qor": round(offered / 1e6, 6),
        }

    if floor and offered >= floor:
        counter = (offered + target) // 2 if target else (offered + floor) // 2
        coarse = _band_counter(counter)
        return {
            "status": "countered",
            "reason": "above_floor_below_target",
            "auto_accept": False,
            "active": True,
            "rounds_used": rounds_used,
            "max_rounds": max_rounds,
            "offered_qor": round(offered / 1e6, 6),
            "counter_uqor": int(counter),
            "counter_qor": round(coarse / 1e6, 6),
        }

    return {
        "status": "rejected",
        "reason": "below_floor",
        "auto_accept": False,
        "active": True,
        "rounds_used": rounds_used,
        "max_rounds": max_rounds,
        "offered_qor": round(offered / 1e6, 6),
        "distance_bucket": _distance_bucket(floor, offered),
    }


def _median(values: list[int]) -> float:
    return float(statistics.median(values)) if values else 0.0


def ai_recommendation(listing=None) -> dict:
    """Comparable-price stats from Listing objects for explainability.

    Computes median completed (sold) and active prices — scoped to the
    listing's category when one is set — and their ratio. Returns no
    floor/target values.
    """
    from apps.marketplace.models import Listing

    category = getattr(listing, "category", None) if listing is not None else None
    sold_qs = Listing.objects.filter(status=Listing.Status.SOLD).exclude(price_uqor=0)
    active_qs = Listing.objects.filter(status=Listing.Status.ACTIVE).exclude(price_uqor=0)
    if category is not None:
        sold_qs = sold_qs.filter(category=category)
        active_qs = active_qs.filter(category=category)

    sold_prices = [int(p) for p in sold_qs.values_list("price_uqor", flat=True)]
    active_prices = [int(p) for p in active_qs.values_list("price_uqor", flat=True)]

    median_sold = _median(sold_prices)
    median_active = _median(active_prices)
    ratio = (median_sold / median_active) if median_active else 0.0

    suggestion = None
    if listing is not None and median_sold:
        current = int(listing.price_uqor or 0)
        if current:
            suggested = int(round(current * ratio)) if ratio else int(round(median_sold))
            suggestion = {
                "suggested_qor": round(suggested / 1e6, 6),
                "basis": "category median sold vs active" if category else "market median sold vs active",
            }

    return {
        "sample_count": len(sold_prices),
        "active_sample_count": len(active_prices),
        "median_sold_qor": round(median_sold / 1e6, 6) if median_sold else None,
        "median_active_qor": round(median_active / 1e6, 6) if median_active else None,
        "price_ratio": round(ratio, 4) if ratio else None,
        "suggestion": suggestion,
    }


def build_quote(listing, buyer_evm: str, price_uqor: int, expires_minutes: int = 30) -> dict:
    """Build a signed seller quote for purchaseWithQuote (testnet demo).

    The seller's ML-DSA-87 signature is produced server-side ONLY for
    demo wallets derived from SWEEFT_DEPLOYER_MNEMONIC (testnet-only,
    same custody as the rest of the demo relayer). Real QoreX users
    sign the returned buildQuoteMessage bytes in their wallet instead;
    the endpoint returns needs_seller_signature in that case.
    """
    import time
    from apps.marketplace.models import Listing

    if not listing or listing.status != Listing.Status.ACTIVE:
        return {"error": "listing is not active"}
    price_wei = int(price_uqor) * 10**12
    if price_wei <= 0 or price_wei > int(listing.price_uqor) * 10**12:
        return {"error": "quote price outside asking price"}
    expires_at = int(time.time()) + expires_minutes * 60

    from integrations.qorechain.client import get_evm_client
    w3 = get_evm_client()
    try:
        from integrations.qorechain.contracts import artifact_path
        from integrations.qorechain.contracts_base import load_abi, make_contract
        import os
        address = os.getenv("SWEEFT_MARKETPLACE_ADDRESS", "")
        market = make_contract(w3, address, load_abi(artifact_path("SweeftMarketplace")))
        nonce = int(market.functions.quoteNonce(listing.on_chain_id, w3.to_checksum_address(buyer_evm)).call())
        message = bytes(market.functions.buildQuoteMessage(
            listing.on_chain_id, w3.to_checksum_address(buyer_evm), price_wei, expires_at, nonce).call())
    except Exception as exc:
        return {"error": f"quote build failed: {exc}"}

    # Demo-seller signing (testnet mnemonic wallets only).
    import os
    mnemonic = os.getenv("SWEEFT_DEPLOYER_MNEMONIC", "").strip()
    from qorsdk import derive_unified_account, pqc_sign
    for idx in range(30):
        try:
            acct = derive_unified_account(mnemonic, index=idx)
        except Exception:
            break
        if acct.evm.lower() == (listing.seller.evm_address or "").lower():
            sig = pqc_sign(acct.pqc.secret_key, message)
            return {"ok": True, "listing_id": listing.on_chain_id, "price_wei": str(price_wei),
                    "expires_at": expires_at, "nonce": nonce, "message_hex": "0x" + message.hex(),
                    "signature_hex": "0x" + bytes(sig).hex(), "needs_seller_signature": False}
    return {"ok": True, "listing_id": listing.on_chain_id, "price_wei": str(price_wei),
            "expires_at": expires_at, "nonce": nonce, "message_hex": "0x" + message.hex(),
            "signature_hex": None, "needs_seller_signature": True,
            "note": "Seller signs message_hex (ML-DSA-87) in QoreX, then calls purchaseWithQuote."}
