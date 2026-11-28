"""AI views — chat page plus the JSON chat API the page calls."""

from __future__ import annotations

import json
import logging
from datetime import timedelta
from decimal import Decimal

from django.http import JsonResponse
from django.utils import timezone
from django.views.decorators.http import require_GET, require_POST

from apps.ai.models import Conversation, Mandate, Message, SellerAgentMandate
from apps.participants.models import Participant

from .services.orchestrator import run_chat

logger = logging.getLogger(__name__)


def _participant_for(request) -> Participant | None:
    """Participant for the connected wallet, provisioned on first use.

    A freshly connected wallet may have no row yet (the indexer only creates
    rows for wallets it has seen on chain). Without provisioning, the landing
    page would keep showing Connect wallet and the budget form would 401.
    """
    account = request.session.get("wallet_account") or {}
    wallet = account.get("evm", "")
    if not wallet:
        return None
    participant = Participant.objects.filter(evm_address__iexact=wallet).first()
    if participant is None and account.get("qor"):
        participant = Participant.objects.filter(qor_address__iexact=account["qor"]).first()
    if participant is None:
        participant = Participant.objects.create(
            display_name=f"Wallet {wallet[:6]}...{wallet[-4:]}",
            evm_address=wallet.lower(),
            qor_address=account.get("qor") or None,
            wallet_linked_at=timezone.now(),
        )
    return participant


def assistant_context(request) -> dict:
    """Chat data for the landing page assistant section."""
    participant = _participant_for(request)
    conversations = []
    recent_messages = []
    if participant:
        conversations = list(participant.conversations.all()[:10])
        recent_messages = list(
            Message.objects.filter(conversation__participant=participant).select_related("conversation").order_by("-created_at")[:40]
        )[::-1]
    return {
        "conversations": conversations,
        "recent_messages": recent_messages,
        # Session is the source of truth for connection, not the participant
        # row, so a connected wallet never sees the Connect prompt again.
        "wallet_attached": bool((request.session.get("wallet_account") or {}).get("evm")),
        "api_ready": bool(__import__("os").getenv("MODEL_API_KEY")),
    }


def assistant(request):
    """The assistant lives on the landing page now."""
    from django.shortcuts import redirect

    return redirect("/#ai-assistant")


@require_POST
def mandate_set(request):
    """Create/activate a spending mandate for the connected wallet (QOR caps)."""
    from apps.ai.services.tools import _active_mandate

    participant = _participant_for(request)
    if not participant:
        return JsonResponse({"error": "connect your wallet first"}, status=401)

    try:
        per_tx = int(Decimal(request.POST.get("per_tx_qor", "0")) * 1_000_000)
        daily = int(Decimal(request.POST.get("daily_qor", "0")) * 1_000_000)
        days = int(request.POST.get("days", "7"))
    except Exception:
        return JsonResponse({"error": "caps must be numbers"}, status=400)
    if per_tx <= 0 or daily < per_tx or days < 1 or days > 90:
        return JsonResponse(
            {"error": "per-tx must be > 0, daily >= per-tx, duration 1-90 days"},
            status=400,
        )

    # One active mandate per wallet: supersede the previous activation.
    wallet = (request.session.get("wallet_account") or {}).get("evm", "")
    previous = _active_mandate(wallet)
    if previous:
        previous.state = previous.State.PAUSED
        previous.save(update_fields=["state"])

    mandate = Mandate.objects.create(
        owner=participant,
        agent_label="sweeft-buyer",
        per_tx_limit_uqor=per_tx,
        daily_limit_uqor=daily,
        state=Mandate.State.ACTIVE,
        autopilot_allowed=bool(request.POST.get("autopilot_allowed")),
        expires_at=timezone.now() + timedelta(days=days),
    )
    return JsonResponse({"ok": True, "mandate_id": mandate.pk, "per_tx_qor": per_tx / 1_000_000, "daily_qor": daily / 1_000_000})


@require_POST
def mandate_pause_revoke(request, mandate_id: int, action: str):
    """Pause (stops spending, resumable) or revoke (terminal) a mandate."""
    participant = _participant_for(request)
    if not participant:
        return JsonResponse({"error": "connect your wallet first"}, status=401)
    mandate = Mandate.objects.filter(pk=mandate_id, owner=participant).first()
    if not mandate:
        return JsonResponse({"error": "mandate not found"}, status=404)
    if action == "pause":
        mandate.state = Mandate.State.PAUSED
    elif action == "resume":
        mandate.state = Mandate.State.ACTIVE
    elif action == "revoke":
        mandate.state = Mandate.State.REVOKED
    else:
        return JsonResponse({"error": "unknown action"}, status=400)
    mandate.save(update_fields=["state"])
    return JsonResponse({"ok": True, "state": mandate.state})


def _parse_json_body(request):
    try:
        return json.loads(request.body or b"{}")
    except json.JSONDecodeError:
        return {}


@require_POST
def seller_mandate_set(request):
    """Set a seller-agent mandate for the connected wallet's own listing.

    Accepts JSON or form fields: listing_id, floor_qor/floor_uqor,
    target_qor/target_uqor, strategy, max_rounds, auto_accept, days.
    Floor/target are never echoed back.
    """
    from apps.marketplace.models import Listing

    participant = _participant_for(request)
    if not participant:
        return JsonResponse({"error": "connect your wallet first"}, status=401)

    data = _parse_json_body(request)
    if not data and request.POST:
        data = dict(request.POST)

    def _get(key, *alts):
        for k in (key, *alts):
            if data.get(k) not in (None, ""):
                return data.get(k)
        return None

    try:
        listing_id = int(_get("listing_id", "listing_id"))
    except (TypeError, ValueError):
        return JsonResponse({"error": "listing_id is required"}, status=400)

    listing = Listing.objects.filter(on_chain_id=listing_id).first()
    if not listing:
        return JsonResponse({"error": "listing not found"}, status=404)
    if listing.seller_id != participant.id:
        return JsonResponse({"error": "not your listing"}, status=403)

    try:
        if _get("floor_uqor"):
            floor_uqor = int(_get("floor_uqor"))
        else:
            floor_uqor = int(Decimal(str(_get("floor_qor", "0"))) * 1_000_000)
        if _get("target_uqor"):
            target_uqor = int(_get("target_uqor"))
        elif _get("target_qor"):
            target_uqor = int(Decimal(str(_get("target_qor"))) * 1_000_000)
        else:
            target_uqor = floor_uqor
    except Exception:
        return JsonResponse({"error": "floor/target must be numbers"}, status=400)

    if floor_uqor <= 0 or target_uqor < floor_uqor:
        return JsonResponse({"error": "floor must be > 0 and target >= floor"}, status=400)

    try:
        max_rounds = int(_get("max_rounds") or 5)
    except (TypeError, ValueError):
        return JsonResponse({"error": "max_rounds must be a number"}, status=400)
    if max_rounds < 1 or max_rounds > 20:
        return JsonResponse({"error": "max_rounds must be 1-20"}, status=400)

    strategy = str(_get("strategy") or SellerAgentMandate.Strategy.BALANCED).lower()
    if strategy not in {c.value for c in SellerAgentMandate.Strategy}:
        return JsonResponse({"error": "unknown strategy"}, status=400)

    raw_auto = _get("auto_accept")
    auto_accept = raw_auto is True or str(raw_auto).lower() in ("1", "true", "yes", "on", "y") if raw_auto is not None else True
    # Default: auto-accept ON for a fresh seller mandate so negotiations
    # can auto-accept; callers may pass auto_accept=false to disable.
    try:
        days = int(_get("days") or 30)
    except (TypeError, ValueError):
        return JsonResponse({"error": "days must be a number"}, status=400)
    if days < 1 or days > 365:
        return JsonResponse({"error": "days must be 1-365"}, status=400)

    # Supersede any previous active mandate for this listing+seller.
    previous = SellerAgentMandate.objects.filter(
        listing=listing, seller=participant, state=SellerAgentMandate.State.ACTIVE
    )
    previous.update(state=SellerAgentMandate.State.PAUSED)

    mandate = SellerAgentMandate.objects.create(
        listing=listing,
        seller=participant,
        floor_uqor=floor_uqor,
        target_uqor=target_uqor,
        strategy=strategy,
        max_rounds=max_rounds,
        auto_accept=bool(auto_accept),
        state=SellerAgentMandate.State.ACTIVE,
        expires_at=timezone.now() + timedelta(days=days),
    )
    return JsonResponse(
        {
            "ok": True,
            "mandate_id": mandate.pk,
            "listing_id": listing.on_chain_id,
            "state": mandate.state,
            "strategy": mandate.strategy,
            "max_rounds": mandate.max_rounds,
            "auto_accept": mandate.auto_accept,
            "expires_at": mandate.expires_at.isoformat(),
        }
    )


@require_GET
def seller_mandate_status(request, listing_id: int):
    """Status of the seller-agent mandate for a listing (no floor/target leak)."""
    from apps.marketplace.models import Listing

    listing = Listing.objects.filter(on_chain_id=int(listing_id)).first()
    if not listing:
        return JsonResponse({"error": "listing not found"}, status=404)
    mandate = (
        SellerAgentMandate.objects.filter(listing=listing, seller=listing.seller)
        .order_by("-created_at")
        .first()
    )
    if mandate is None:
        return JsonResponse(
            {"ok": True, "listing_id": listing.on_chain_id, "state": "none", "active": False}
        )
    if mandate.state == SellerAgentMandate.State.ACTIVE and mandate.expires_at < timezone.now():
        mandate.state = SellerAgentMandate.State.EXPIRED
        mandate.save(update_fields=["state", "updated_at"])
    return JsonResponse(
        {
            "ok": True,
            "listing_id": listing.on_chain_id,
            "mandate_id": mandate.pk,
            "state": mandate.state,
            "active": mandate.state == SellerAgentMandate.State.ACTIVE,
            "strategy": mandate.strategy,
            "max_rounds": mandate.max_rounds,
            "auto_accept": mandate.auto_accept,
            "expires_at": mandate.expires_at.isoformat(),
        }
    )


@require_GET
def seller_quote(request, listing_id: int):
    """Build a seller quote for purchaseWithQuote (buyer wallet required)."""
    from apps.marketplace.models import Listing

    participant = _participant_for(request)
    if not participant:
        return JsonResponse({"error": "connect your wallet first"}, status=401)
    listing = Listing.objects.filter(on_chain_id=int(listing_id)).first()
    if not listing:
        return JsonResponse({"error": "listing not found"}, status=404)
    try:
        price_uqor = int(float(request.GET.get("price_qor", "0")) * 1e6)
    except (TypeError, ValueError):
        price_uqor = 0
    if price_uqor <= 0:
        # Default to current asking price (accepted outcome of negotiation).
        price_uqor = int(listing.price_uqor or 0)
    from .services.seller_agent import build_quote

    return JsonResponse(build_quote(listing, participant.evm_address, price_uqor))


@require_POST
def chat(request):
    """One chat turn: persist the message, run the model+tools, persist the reply."""
    try:
        payload = json.loads(request.body or b"{}")
    except json.JSONDecodeError:
        return JsonResponse({"error": "invalid JSON body"}, status=400)

    user_message = str(payload.get("message", "")).strip()
    if not user_message:
        return JsonResponse({"error": "message is required"}, status=400)
    if len(user_message) > 2000:
        return JsonResponse({"error": "message too long (max 2000 chars)"}, status=400)

    wallet = (request.session.get("wallet_account") or {}).get("evm", "")
    participant = _participant_for(request)

    conversation = None
    if participant:
        conversation_id = payload.get("conversation_id")
        if conversation_id:
            conversation = Conversation.objects.filter(pk=conversation_id, participant=participant).first()
        if conversation is None:
            conversation = Conversation.objects.create(participant=participant, title=user_message[:60])
            if not conversation.title:
                conversation.title = user_message[:60]

    history = []
    if conversation:
        tuples = list(Message.objects.filter(conversation=conversation).order_by("created_at").values_list("role", "content"))
        tuples = tuples[-10:] if len(tuples) > 10 else tuples
        history = [{"role": role, "content": content} for role, content in tuples]
        Message.objects.create(conversation=conversation, role=Message.Role.USER, content=user_message)

    try:
        result = run_chat(user_message, wallet=(wallet or None), history=history)
    except Exception as exc:  # pragma: no cover
        logger.exception("AI chat failed")
        return JsonResponse({"error": f"AI service error: {exc}"}, status=502)

    if conversation:
        Message.objects.create(
            conversation=conversation,
            role=Message.Role.ASSISTANT,
            content=result["text"],
            tool_payload={"tool_calls": result.get("tool_calls", [])},
        )
        conversation.save(update_fields=["updated_at"])

    return JsonResponse(
        {
            "ok": True,
            "text": result["text"],
            "tool_calls": result.get("tool_calls", []),
            "conversation_id": conversation.pk if conversation else None,
        }
    )


@require_GET
def conversation_detail(request, conversation_id: int):
    """Return one conversation's messages (for the page's local history links)."""
    participant = _participant_for(request)
    if not participant:
        return JsonResponse({"error": "connect your wallet first"}, status=401)
    conversation = Conversation.objects.filter(pk=conversation_id, participant=participant).first()
    if not conversation:
        return JsonResponse({"error": "not found"}, status=404)
    messages = Message.objects.filter(conversation=conversation).order_by("created_at")
    return JsonResponse(
        {
            "id": conversation.pk,
            "title": conversation.title,
            "messages": [
                {"role": m.role, "content": m.content, "tool_payload": m.tool_payload} for m in messages
            ],
        }
    )
