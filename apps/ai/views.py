"""AI views — chat page plus the JSON chat API the page calls."""

from __future__ import annotations

import json
import logging

from django.http import JsonResponse
from django.shortcuts import render
from django.views.decorators.http import require_GET, require_POST

from apps.ai.models import Conversation, Message
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
    if participant:
        conversations = list(participant.conversations.all()[:10])
        recent_messages = list(
            Message.objects.filter(conversation__participant=participant).select_related("conversation").order_by("-created_at")[:40]
        )[::-1]
    return render(
        request,
        "ai/index.html",
        {
            "conversations": conversations,
            "recent_messages": recent_messages,
            "wallet_attached": bool(participant),
            "api_ready": bool(__import__("os").getenv("MODEL_API_KEY")),
        },
    )


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
