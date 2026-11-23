"""Blockchain app views — indexer control for the UI."""

from __future__ import annotations

import logging
import os
import time

from django.http import JsonResponse
from django.views.decorators.http import require_POST

from .services.indexer import sync_all

logger = logging.getLogger(__name__)

# Cap the work per call so a single request cannot trigger a huge scan.
MAX_BLOCKS_PER_SYNC = 2_000
# Simple in-process rate limit (per client). Good enough for a single worker.
_RATE_LIMIT_SECONDS = 30
_last_sync: dict[str, float] = {}


def _client_ip(request) -> str:
    forwarded = request.META.get("HTTP_X_FORWARDED_FOR", "")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.META.get("REMOTE_ADDR", "unknown")


def _authorized(request) -> bool:
    expected = os.getenv("SWEEFT_INTERNAL_TOKEN", "")
    if expected and request.headers.get("X-Internal-Token", "") == expected:
        return True
    user = getattr(request, "user", None)
    return bool(user and user.is_authenticated and user.is_staff)


@require_POST
def sync_now(request):
    """Run a bounded indexer pass (internal token or staff session only)."""
    if not _authorized(request):
        return JsonResponse({"error": "not authorized to trigger a sync"}, status=403)

    ip = _client_ip(request)
    now = time.monotonic()
    last = _last_sync.get(ip, 0)
    if now - last < _RATE_LIMIT_SECONDS:
        retry = int(_RATE_LIMIT_SECONDS - (now - last))
        return JsonResponse({"error": "slow down", "retry_after": retry}, status=429)
    _last_sync[ip] = now

    try:
        results = sync_all(max_blocks=MAX_BLOCKS_PER_SYNC)
    except Exception as exc:  # pragma: no cover
        logger.exception("indexer sync failed")
        return JsonResponse({"error": str(exc)}, status=502)
    return JsonResponse({"ok": True, "handled": results})
