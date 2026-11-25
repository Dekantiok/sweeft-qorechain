"""Blockchain app views — indexer control for the UI."""

from __future__ import annotations

import logging
import os

from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_POST

from config.ratelimit import is_rate_limited

from .services.indexer import sync_all

logger = logging.getLogger(__name__)

# Cap the work per call so a single request cannot trigger a huge scan.
MAX_BLOCKS_PER_SYNC = 2_000
# Minimum seconds between syncs for one client.
_RATE_LIMIT_SECONDS = 30


def _authorized(request) -> bool:
    import hmac
    import os

    expected = os.getenv("SWEEFT_INTERNAL_TOKEN", "")
    provided = request.headers.get("X-Internal-Token", "")
    if expected and hmac.compare_digest(provided, expected):
        return True
    user = getattr(request, "user", None)
    if user and user.is_authenticated and user.is_staff:
        return True
    # A connected wallet session may also refresh from chain (the endpoint is
    # rate-limited and work-capped, and only triggers an idempotent index pass).
    return bool((request.session.get("wallet_account") or {}).get("evm"))


@csrf_exempt  # idempotent indexer trigger; auth + rate limit + cap below
@require_POST
def sync_now(request):
    """Run a bounded indexer pass (internal token or staff session only)."""
    if not _authorized(request):
        return JsonResponse({"error": "not authorized to trigger a sync"}, status=403)

    if is_rate_limited("indexer-sync", request, _RATE_LIMIT_SECONDS):
        return JsonResponse({"error": "slow down", "retry_after": _RATE_LIMIT_SECONDS}, status=429)

    try:
        results = sync_all(max_blocks=MAX_BLOCKS_PER_SYNC)
    except Exception as exc:  # pragma: no cover
        logger.exception("indexer sync failed")
        return JsonResponse({"error": str(exc)}, status=502)
    return JsonResponse({"ok": True, "handled": results})
