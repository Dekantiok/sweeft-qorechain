"""Blockchain app views — indexer control for the UI."""

from __future__ import annotations

import logging

from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_POST

from .services.indexer import sync_all

logger = logging.getLogger(__name__)


@csrf_exempt
@require_POST
def sync_now(request):
    """Run an indexer pass immediately (the UI 'Refresh from chain' button)."""
    try:
        results = sync_all(max_blocks=30_000)
    except Exception as exc:  # pragma: no cover
        logger.exception("indexer sync failed")
        return JsonResponse({"error": str(exc)}, status=502)
    return JsonResponse({"ok": True, "handled": results})
