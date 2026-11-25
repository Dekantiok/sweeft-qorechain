"""Template context processors."""

from __future__ import annotations


def csp_nonce(request):
    """Expose the per-request CSP nonce to templates."""
    return {"csp_nonce": getattr(request, "csp_nonce", "")}
