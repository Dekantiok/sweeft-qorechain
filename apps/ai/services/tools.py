"""Sweeft AI tools — the only functions the model may call.

Every tool runs through the same Django business logic as the UI forms and
the APIs, and lands the same records. Tools NEVER sign or move money.
"""

from __future__ import annotations

import hashlib
import inspect
import json
import logging
import time
from decimal import Decimal, InvalidOperation
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
        price = float(listing.price_uqor) / 1e6  # uqor -> QOR
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
    from apps.blockchain.services.reads import escrow_state

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


def _decimal(value) -> Decimal:
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return Decimal(0)


def _active_mandate(wallet: str | None):
    from apps.ai.models import Mandate

    # Never resolve a mandate without an explicit wallet — otherwise one user's
    # mandate could be applied to another user's request (N-11).
    if not wallet:
        return None
    return (
        Mandate.objects.filter(state=Mandate.State.ACTIVE, owner__evm_address__iexact=wallet)
        .order_by("-created_at")
        .first()
    )


def _daily_spend_uqor(mandate) -> int:
    from datetime import timedelta

    from django.utils import timezone

    from apps.ai.models import AgentAction

    since = timezone.now() - timedelta(hours=24)
    total = 0
    actions = AgentAction.objects.filter(
        mandate=mandate,
        created_at__gte=since,
        outcome__in=[AgentAction.Outcome.EXECUTED, AgentAction.Outcome.PLANNED],
    )
    for action in actions:
        try:
            total += int(action.payload.get("amount_uqor", 0) or 0)
        except (TypeError, ValueError):
            continue
    return total


def tool_check_mandate(action: str = "purchase", amount_qor: float = 0, wallet: str | None = None) -> dict:
    """Enforce the owner's mandate in code (per-tx and rolling 24h caps).

    The mandate is the off-chain policy; the on-chain spending rule registered
    by the owner remains the hard cap. With no active mandate, the agent
    refuses autonomous spend rather than acting unbounded.
    """
    amount = _decimal(amount_qor)
    amount_uqor = int((amount * Decimal(1_000_000)).to_integral_value())
    mandate = _active_mandate(wallet)
    if not mandate:
        return {
            "action": action,
            "amount_uqor": amount_uqor,
            "within_caps": False,
            "reason": "no active mandate — the agent will not spend autonomously until you create one",
        }

    from django.utils import timezone

    if mandate.expires_at and mandate.expires_at < timezone.now():
        return {"action": action, "amount_uqor": amount_uqor, "within_caps": False, "reason": "mandate expired"}

    per_tx = int(mandate.per_tx_limit_uqor)
    daily = int(mandate.daily_limit_uqor)
    if amount_uqor > per_tx:
        return {
            "action": action,
            "amount_uqor": amount_uqor,
            "within_caps": False,
            "reason": f"amount {amount_uqor} uqor exceeds the per-tx cap {per_tx} uqor",
        }

    spent = _daily_spend_uqor(mandate)
    if spent + amount_uqor > daily:
        return {
            "action": action,
            "amount_uqor": amount_uqor,
            "within_caps": False,
            "reason": f"daily cap reached ({spent}+{amount_uqor} > {daily} uqor)",
        }

    return {
        "action": action,
        "amount_uqor": amount_uqor,
        "within_caps": True,
        "mandate_id": mandate.pk,
        "per_tx_limit_uqor": per_tx,
        "daily_limit_uqor": daily,
        "daily_spent_uqor": spent,
    }


def tool_execute_autopilot(escrow_id: int, wallet: str | None = None) -> dict:
    """Submit a stored pre-signed release if the escrow is eligible.

    This is the autopilot moment: the AI executes the exact authorization the
    buyer signed once. It cannot alter recipient/amount/nonce — the contract
    checks them. Mandate caps are re-checked first. The caller's wallet is
    resolved server-side and must be the escrow's buyer (N-11).
    """
    from apps.blockchain.services.reads import escrow_state
    from apps.blockchain.services.relayer import submit_release as relayer_release
    from apps.escrow.models import Escrow

    escrow = Escrow.objects.filter(on_chain_id=int(escrow_id)).first()
    if not escrow:
        return {"error": f"escrow {escrow_id} not found"}
    if not wallet or (escrow.buyer and escrow.buyer.evm_address.lower() != wallet.lower()):
        return {"error": "not authorized for this escrow"}
    if not escrow.autopilot_enabled or not escrow.autopilot_release_signature_b64:
        return {"error": "no pre-authorization stored — the buyer must sign once in QoreX first (Autopilot on the escrow page)"}

    # Live chain state first (G8): caps must be checked against the TRUE
    # on-chain amount, never the indexer mirror, which can lag behind.
    try:
        state = escrow_state(int(escrow_id))
    except Exception as exc:
        return {"error": f"chain read failed: {exc}"}
    live_amount_wei = int(state.get("amount_wei", 0))
    live_amount_uqor = live_amount_wei // 10**12
    live_amount_qor = live_amount_wei / 10**18

    # Autopilot is opt-in per mandate: only runs when the owner explicitly
    # enabled autonomous execution when setting the budget.
    mandate = _active_mandate(wallet)
    if mandate is None or not getattr(mandate, "autopilot_allowed", False):
        return {
            "error": "autopilot is not enabled on this mandate — set it in the AI page budget form (Autopilot: yes)",
            "state": state,
        }

    # Django-side mandate check (the chain rule is the hard cap)
    caps = tool_check_mandate("release", live_amount_qor, wallet=wallet)
    if not caps.get("within_caps"):
        from apps.ai.models import AgentAction

        AgentAction.objects.create(
            mandate=mandate,
            action="execute_autopilot",
            payload={"escrow_id": int(escrow_id), "amount_uqor": live_amount_uqor},
            outcome=AgentAction.Outcome.REFUSED_POLICY,
            detail=str(caps.get("reason", ""))[:500],
        )
        return {"error": f"outside mandate caps — refusing to execute: {caps.get('reason', '')}"}

    if state["status"] == 2:
        return {"ok": True, "already": True, "tx_hash": escrow.release_tx or escrow.autopilot_execute_tx}
    if not state["release_eligible"]:
        return {"error": "not yet release-eligible — waiting for attestation/inspection", "state": state}

    import base64

    signature = base64.b64decode(escrow.autopilot_release_signature_b64)
    try:
        result = relayer_release(int(escrow_id), signature)
    except Exception as exc:
        return {"error": str(exc)[:300]}

    escrow.autopilot_execute_tx = result["tx_hash"]
    # A pre-signed release is single-use; clear it after a successful execution.
    escrow.autopilot_enabled = False
    escrow.autopilot_release_signature_b64 = ""
    escrow.save(update_fields=["autopilot_execute_tx", "autopilot_enabled", "autopilot_release_signature_b64", "updated_at"])

    from apps.ai.models import AgentAction

    if mandate:
        AgentAction.objects.create(
            mandate=mandate,
            action="execute_autopilot",
            payload={"escrow_id": int(escrow_id), "amount_uqor": live_amount_uqor},
            outcome=AgentAction.Outcome.EXECUTED,
            tx_hash=result["tx_hash"],
            detail="pre-signed release submitted within mandate",
        )

    return {"ok": True, "tx_hash": result["tx_hash"], "escrow_id": int(escrow_id), "actor": "AI autopilot (pre-signed release)"}


def tool_negotiate(listing_id: int, offered_qor: float = 0, details: str = "", wallet: str | None = None) -> dict:
    """Bargain against a listing's floor without revealing it.

    The seller's floor number is never returned. Outcomes:
      accepted  — offer is at/above the floor, seller may update the on-chain price
      countered — below floor, ships a mid counter
      rejected  — far below floor, no counter
    All within the buyer's mandate caps (checked).
    """
    from apps.marketplace.models import Listing
    from apps.marketplace.negotiation_models import Negotiation

    listing = Listing.objects.filter(on_chain_id=int(listing_id)).first()
    if not listing:
        return {"error": f"listing {listing_id} not found"}
    if listing.status != Listing.Status.ACTIVE:
        return {"error": "listing is not active"}

    # The negotiation belongs to the wallet that authorized it (injected
    # server-side by execute_tool — a model can never supply it). Refuse
    # unattributed or self-negotiations instead of recording a placeholder
    # buyer, which previously hid who actually made the offer.
    buyer = _participant(wallet) if wallet else None
    if buyer is None:
        return {"error": "no Sweeft participant for the connected wallet — negotiation refused"}
    if listing.seller_id == buyer.id:
        return {"error": "cannot negotiate with yourself"}

    try:
        offered = int(round(float(offered_qor) * 1e6))  # uqor, matches stored fields
    except (TypeError, ValueError):
        return {"error": "offered_qor must be a number"}

    # Mandate check first — the AI can never bargain above caps
    from .tools import tool_check_mandate

    caps = tool_check_mandate("purchase", float(offered_qor) if offered_qor else 0, wallet=wallet)
    if not caps.get("within_caps"):
        return {"error": "offer outside mandate caps — refusing to negotiate"}

    # Seller-agent path: an active auto-accept mandate decides deterministically.
    # Expired mandates are transitioned and fall through to the legacy path.
    from apps.ai.models import SellerAgentMandate
    from apps.ai.services.seller_agent import _is_expired, evaluate_offer

    seller_mandate = (
        SellerAgentMandate.objects.filter(
            listing=listing,
            seller=listing.seller,
            state=SellerAgentMandate.State.ACTIVE,
            auto_accept=True,
        )
        .order_by("-created_at")
        .first()
    )
    if seller_mandate is not None and _is_expired(seller_mandate):
        seller_mandate.state = SellerAgentMandate.State.EXPIRED
        seller_mandate.save(update_fields=["state", "updated_at"])
        seller_mandate = None

    if seller_mandate is not None:
        rounds_used = Negotiation.objects.filter(listing=listing, buyer=buyer).count()
        decision = evaluate_offer(listing, offered, rounds_used=rounds_used)
        decision_status = decision.get("status", "rejected")

        state_map = {
            "accepted": Negotiation.State.ACCEPTED,
            "countered": Negotiation.State.COUNTERED,
            "rejected": Negotiation.State.REJECTED,
        }
        kwargs = {
            "listing": listing,
            "buyer": buyer,
            "proposed_uqor": offered,
            "details": str(details)[:1000],
            "state": state_map.get(decision_status, Negotiation.State.REJECTED),
        }
        if decision_status == "countered" and decision.get("counter_uqor") is not None:
            kwargs["counter_uqor"] = int(decision["counter_uqor"])
        negotiation = Negotiation.objects.create(**kwargs)

        result = {
            "ok": True,
            "status": decision_status,
            "negotiation_id": negotiation.pk,
            "listing_id": listing.on_chain_id,
            "offered_qor": round(offered / 1e6, 6),
            "rounds_used": int(decision.get("rounds_used", rounds_used)),
            "max_rounds": int(decision.get("max_rounds", seller_mandate.max_rounds)),
            "seller_agent": {
                "status": decision_status,
                "reason": decision.get("reason", ""),
                "active": bool(decision.get("active", True)),
            },
            "auto_accept": False,
        }
        if decision_status == "accepted":
            result["auto_accept"] = True
            result["note"] = (
                "Seller agent has auto-accepted. The buyer now purchases at this price "
                "(the seller updates the listing price first if needed)."
            )
            mandate = _active_mandate(wallet)
            if mandate:
                from apps.ai.models import AgentAction

                AgentAction.objects.create(
                    mandate=mandate,
                    action="negotiate_accepted",
                    payload={"listing_id": listing.on_chain_id, "amount_uqor": offered},
                    outcome=AgentAction.Outcome.PLANNED,
                    detail="accepted negotiation reserves daily budget until purchase resolves",
                )
        elif decision_status == "countered":
            if decision.get("counter_qor") is not None:
                result["counter_qor"] = decision["counter_qor"]
            result["note"] = (
                "Seller agent counter-offered somewhere up to this estimate. "
                "Accept and the AI drafts a purchase at the agreed price — your wallet still signs."
            )
        else:
            if decision.get("distance_bucket"):
                result["distance_bucket"] = decision["distance_bucket"]
            if decision.get("reason"):
                result["reason"] = decision["reason"]
            result["note"] = "Offer rejected by the seller agent — try closer to the list price, or buy directly."
        return result

    floor = int(listing.floor_price_uqor or 0)
    # No floor (or seller auto-accepts): any offer inside mandate is a deal.
    if not floor or (listing.auto_accept_floor and offered >= floor):
        negotiation = Negotiation.objects.create(
            listing=listing,
            buyer=buyer,
            proposed_uqor=offered,
            details=str(details)[:1000],
            state=Negotiation.State.ACCEPTED,
        )
        # Reserve the agreed spend against the daily cap (PLANNED ledger).
        mandate = _active_mandate(wallet)
        if mandate:
            from apps.ai.models import AgentAction

            AgentAction.objects.create(
                mandate=mandate,
                action="negotiate_accepted",
                payload={"listing_id": listing.on_chain_id, "amount_uqor": offered},
                outcome=AgentAction.Outcome.PLANNED,
                detail="accepted negotiation reserves daily budget until purchase resolves",
            )
        return {
            "ok": True,
            "status": "accepted",
            "negotiation_id": negotiation.pk,
            "listing_id": listing.on_chain_id,
            "offered_qor": round(offered / 1e6, 6),
            "note": "Seller has accepted. The buyer now purchases at this price (the seller updates the listing price first if needed).",
        }

    # Below floor: counter at midpoint when close, reject when far. The
    # returned counter is banded (0.05 QOR) so it cannot be inverted into the
    # seller's exact floor; the exact counter stays internal.
    distance_below = floor - offered
    if floor and distance_below <= floor // 5:  # within 20%
        counter = (offered + floor) // 2
        Negotiation.objects.create(
            listing=listing,
            buyer=buyer,
            proposed_uqor=offered,
            counter_uqor=counter,
            details=str(details)[:1000],
            state=Negotiation.State.COUNTERED,
        )
        coarse_counter = -(-counter // 50_000) * 50_000  # round up to a 0.05 QOR band (anti floor-leak)
        return {
            "ok": True,
            "status": "countered",
            "listing_id": listing.on_chain_id,
            "offered_qor": round(offered / 1e6, 6),
            "counter_qor": round(coarse_counter / 1e6, 6),
            "note": "Seller counter-offered somewhere up to this estimate. Accept and the AI drafts a purchase at the agreed price — your wallet still signs.",
        }

    Negotiation.objects.create(
        listing=listing,
        buyer=buyer,
        proposed_uqor=offered,
        details=str(details)[:1000],
        state=Negotiation.State.REJECTED,
    )
    return {
        "ok": True,
        "status": "rejected",
        "listing_id": listing.on_chain_id,
        "offered_qor": round(offered / 1e6, 6),
        "note": "Offer rejected — try closer to the list price, or buy directly.",
    }


def just_accept(listing, offered: int) -> bool:
    floor = int(listing.floor_price_uqor or 0)
    if not floor:
        return False
    return bool(listing.auto_accept_floor and offered >= floor)


TOOLS_REGISTRY = {
    "search_listings": tool_search_listings,
    "get_escrow_status": tool_get_escrow_status,
    "get_reputation": tool_get_reputation,
    "create_listing_draft": tool_create_listing_draft,
    "create_escrow_draft": tool_create_escrow_draft,
    "check_mandate": tool_check_mandate,
    "execute_autopilot": tool_execute_autopilot,
    "negotiate": tool_negotiate,
}


def execute_tool(name: str, wallet: str | None = None, **kwargs) -> dict:
    """Dispatch a model-chosen tool with schema-checked arguments.

    Arguments not in the tool's signature are dropped, and `wallet` is injected
    server-side only — a model can never supply or spoof a wallet (N-11).
    """
    fn = TOOLS_REGISTRY.get(name)
    if not fn:
        return {"error": f"unknown tool {name}"}
    params = inspect.signature(fn).parameters
    args = {k: v for k, v in kwargs.items() if k in params and k != "wallet"}
    if "wallet" in params:
        args["wallet"] = wallet
    try:
        return fn(**args)
    except Exception as exc:  # pragma: no cover
        logger.exception("tool %s failed", name)
        return {"error": str(exc)[:300]}
