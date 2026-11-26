"""Sweeft MCP server — the app's AI tools, callable by any MCP client.

Tools mirror the AI assistant's enforced capabilities (search, escrow
status, mandate check, dispute board). They are **read-only plus policy
checks**: this server never signs, never holds keys and never moves funds —
writes happen in the wallet UI.

Run:
    SWEEFT_API_BASE=http://127.0.0.1:8001 .venv/bin/python packages/mcp/server.py
"""

from __future__ import annotations

import os
import sys

from mcp.server.fastmcp import FastMCP

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))

from sweeft import SweeftClient, evaluate_mandate  # noqa: E402
from sweeft.mandate import Mandate  # noqa: E402

mcp = FastMCP("sweeft")
_client = SweeftClient(os.getenv("SWEEFT_API_BASE", "http://127.0.0.1:8001"))


@mcp.tool()
def search_listings(query: str = "") -> list:
    """Search active marketplace listings (title/description match)."""
    listings = _client.listings(status="active")
    if query:
        tokens = [t for t in query.lower().split() if len(t) > 2]
        listings = [
            l for l in listings
            if any(t in (l["title"] + " " + l.get("description", "")).lower() for t in tokens)
        ]
    return listings[:10]


@mcp.tool()
def get_escrow(escrow_id: int) -> dict:
    """Escrow state including live chain status and proof link."""
    return _client.escrow(escrow_id)


@mcp.tool()
def get_disputes(state: str = "") -> list:
    """Disputes, optionally filtered by state (open/resolved/appealed/final)."""
    return _client.disputes(state=state or None)


@mcp.tool()
def get_board() -> dict:
    """Live dispute-board parameters and resolver pool."""
    return _client.board()


@mcp.tool()
def get_proposals() -> list:
    """DAO proposals with stake-weighted votes."""
    return _client.proposals()


@mcp.tool()
def check_mandate(amount_uqor: int, per_tx_limit_uqor: int, daily_limit_uqor: int, daily_spent_uqor: int = 0) -> dict:
    """Pure policy check: is this spend within a mandate's caps?

    Takes caps as parameters (no DB access needed) and returns the same
    within_caps/reason shape the app enforces.
    """
    mandate = Mandate(
        per_tx_limit_uqor=per_tx_limit_uqor,
        daily_limit_uqor=daily_limit_uqor,
        daily_spent_uqor=daily_spent_uqor,
    )
    return evaluate_mandate(mandate, amount_uqor)


if __name__ == "__main__":
    mcp.run()
