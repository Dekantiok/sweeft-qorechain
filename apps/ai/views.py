"""AI views — chat page plus the JSON chat API the page calls."""

from __future__ import annotations

import json
import logging
from datetime import timedelta
from decimal import Decimal

from django.http import JsonResponse
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_GET, require_POST

from apps.ai.models import Conversation, Mandate, Message
from apps.participants.models import Participant

from .services.orchestrator import run_chat

logger = logging.getLogger(__name__)


def _participant_for(request) -> Participant | None:
    wallet = (request.session.get("wallet_account") or {}).get("evm", "")
    if not wallet:
        return None
    return Participant.objects.filter(evm_address__iexact=wallet).first()


def assistant(request):
    participant = _participant_for(request)
    conversations = []
    recent_messages = []
    mandate = None
    daily_spent = 0
    if participant:
        conversations = list(participant.conversations.all()[:10])
        recent_messages = list(
            Message.objects.filter(conversation__participant=participant).select_related("conversation").order_by("-created_at")[:40]
        )[::-1]
        from apps.ai.services.tools import _active_mandate, _daily_spend_uqor

        mandate = _active_mandate((request.session.get("wallet_account") or {}).get("evm", ""))
        if mandate:
            daily_spent = _daily_spend_uqor(mandate)
    return render(
        request,
        "ai/index.html",
        {
            "conversations": conversations,
            "recent_messages": recent_messages,
            "wallet_attached": bool(participant),
            "api_ready": bool(__import__("os").getenv("MODEL_API_KEY")),
            "mandate": mandate,
            "daily_spent_qor": daily_spent / 1_000_000,
        },
    )


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
