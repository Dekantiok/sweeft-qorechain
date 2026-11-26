"""Orchestrator — wires Meta Model API to Sweeft commerce tools.

The model extracts and proposes; Django validators dispose. Every tool
call is logged to AgentAction. The AI never signs, releases, or raises
mandate limits.
"""

from __future__ import annotations

import json
import logging
import re

from django.conf import settings

from integrations.ai_providers.meta import get_client, get_model_config

from .tools import execute_tool

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are the Sweeft commerce assistant for a post-quantum escrow marketplace on QoreChain.

Rules you must always obey:
- You prepare drafts and answers. A wallet signature and on-chain checks always authorize money movement.
- Never claim you released funds, attested delivery, or moved money yourself.
- If a request would exceed a user's mandate, say so and ask for confirmation.
- Prefer tool calls for anything factual (search listings, read escrow status, check reputation). Never invent prices or balances.

Available tools:
  search_listings(query, max_price_qor)
  get_escrow_status(escrow_id)
  get_reputation(address)
  create_listing_draft(title, description, price_qor, quantity)
  create_escrow_draft(item, seller_hint, amount_qor, delivery_days)
  check_mandate(action, amount_qor)

Output: plain text, short and specific. When you draft something, list the exact
fields so the user can review them before any wallet action.
"""

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "search_listings",
            "description": "Search the on-chain marketplace listings. Returns matching listings with seller and price.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Keywords, e.g. 'laptop'"},
                    "max_price_qor": {"type": "number", "description": "Optional price cap"},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_escrow_status",
            "description": "Read the live on-chain state of one escrow (status, release eligibility, carrier attestation).",
            "parameters": {"type": "object", "properties": {"escrow_id": {"type": "integer"}}, "required": ["escrow_id"]},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_reputation",
            "description": "Read the verified trust score for a wallet address.",
            "parameters": {"type": "object", "properties": {"address": {"type": "string"}}, "required": ["address"]},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_listing_draft",
            "description": "Draft a listing (metadata JSON is stored and hashed). Does NOT publish — the user publishes from their wallet.",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "description": {"type": "string"},
                    "price_qor": {"type": "number"},
                    "quantity": {"type": "integer", "minimum": 1},
                },
                "required": ["title", "price_qor"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_escrow_draft",
            "description": "Draft a purchase (escrow terms). Does NOT create the escrow — the user approves in their wallet.",
            "parameters": {
                "type": "object",
                "properties": {
                    "item": {"type": "string"},
                    "seller_hint": {"type": "string"},
                    "amount_qor": {"type": "number"},
                    "delivery_days": {"type": "number"},
                },
                "required": ["item", "amount_qor"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "negotiate",
            "description": "Bargain with a listing's seller against their floor (floor number is never revealed). Returns accepted/countered/rejected.",
            "parameters": {
                "type": "object",
                "properties": {
                    "listing_id": {"type": "integer"},
                    "offered_qor": {"type": "number"},
                    "details": {"type": "string"},
                },
                "required": ["listing_id", "offered_qor"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "execute_autopilot",
            "description": "Submit a stored pre-signed release for an escrow (Autopilot). Only succeeds if the buyer pre-signed and the escrow is release-eligible. Cannot change terms.",
            "parameters": {
                "type": "object",
                "properties": {"escrow_id": {"type": "integer"}},
                "required": ["escrow_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "check_mandate",
            "description": "Check whether an action fits the user's current mandate caps (per-tx and daily).",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "description": "e.g. purchase"},
                    "amount_qor": {"type": "number"},
                },
                "required": ["action"],
            },
        },
    },
]


def run_chat(user_message: str, *, wallet: str | None = None, history: list[dict] | None = None) -> dict:
    """Run one turn: model → tool calls (if any) → final answer.

    Returns {"text": ..., "tool_calls": [...]}
    """
    config = get_model_config()
    if not config.api_key:
        # No key configured — offline stub so the page still demos the flow.
        return _stub_response(user_message)

    client = get_client()
    messages: list[dict] = [{"role": "system", "content": SYSTEM_PROMPT}]
    for entry in (history or [])[-10:]:
        messages.append({"role": entry["role"], "content": entry["content"]})
    messages.append({"role": "user", "content": user_message})

    response = client.chat.completions.create(
        model=config.reason_model, messages=messages, tools=TOOLS, tool_choice="auto"
    )
    assistant_msg = response.choices[0].message
    tool_calls_out = []

    # Up to 3 rounds of tool calls, so the agent can chain e.g.
    # search -> negotiate -> check_mandate within one turn. Every round's
    # `wallet` is still server-injected (N-11).
    for _ in range(3):
        if not assistant_msg.tool_calls:
            break
        tool_results = []
        for call in assistant_msg.tool_calls:
            name = call.function.name
            try:
                args = json.loads(call.function.arguments or "{}")
            except json.JSONDecodeError:
                args = {}
            # Never let the model supply a wallet; it is injected server-side.
            args.pop("wallet", None)
            result = execute_tool(name, wallet=wallet, **args)
            tool_calls_out.append({"name": name, "args": args})
            tool_results.append(
                {"role": "tool", "tool_call_id": call.id, "content": json.dumps(result)[:2000]}
            )

        messages.append(assistant_msg.model_dump())
        messages.extend(tool_results)
        response = client.chat.completions.create(
            model=config.reason_model, messages=messages, tools=TOOLS, tool_choice="auto"
        )
        assistant_msg = response.choices[0].message

    text = assistant_msg.content or ""
    return {"text": text, "tool_calls": tool_calls_out}


def _stub_response(user_message: str) -> dict:
    """Deterministic fallback used when MODEL_API_KEY is absent (demo mode)."""
    lowered = user_message.lower()
    query_match = re.search(r"(?:buy|find|search|looking for|want)\s+(?:a\s+|an\s+|the\s+|some\s+)?(\w+)", lowered)
    query = query_match.group(1) if query_match else "laptop"
    price_match = re.search(r"under\s+(\d+(?:\.\d+)?)", lowered)
    max_price = float(price_match.group(1)) if price_match else None

    # If it looks like a listing search, actually search.
    if any(w in lowered for w in ("buy", "find", "search", "looking", "want")):
        result = execute_tool("search_listings", query=query, max_price_qor=max_price)
        listings = result.get("listings", [])
        if listings:
            lines = "\n".join(
                f"- {l['title']} — {l['price_qor']} QOR from {l['seller'][:18]}… (#{l['id']})" for l in listings[:3]
            )
            return {
                "text": (
                    f"I found {len(listings)} match(es) for “{query}”:\n{lines}\n\n"
                    "Tell me which one you want and the budget words — I'll draft the escrow for your approval. "
                    "I never release funds myself; your wallet signs."
                ),
                "tool_calls": [{"name": "search_listings", "args": {"query": query}}],
            }
        return {
            "text": f"I searched the marketplace for “{query}” and found nothing yet. Try a broader word (e.g. “machine”, “lamp”) or create a listing draft.",
            "tool_calls": [{"name": "search_listings", "args": {"query": query}}],
        }

    if "escrow" in lowered and "status" in lowered:
        return {
            "text": "Give me the escrow id — I'll read its live on-chain state (funded? delivered? release-eligible?).",
            "tool_calls": [],
        }

    return {
        "text": (
            "I'm the Sweeft commerce assistant (demo mode — no API key configured). I can: "
            "find items in the marketplace, check any escrow's live status, read a seller's trust score, "
            "and draft listings or escrows for you to approve. Try “find a laptop under 200 QOR” or “check escrow 2 status”."
        ),
        "tool_calls": [],
    }
