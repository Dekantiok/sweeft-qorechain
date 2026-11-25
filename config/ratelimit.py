"""Small shared rate-limit helpers.

Uses Django's cache framework so a deployment can point it at a shared cache
(Redis/Memcached) and have the limit apply across workers. The default locmem
cache is per-process; single-worker deployments are fine, multi-worker ones
should configure a shared cache.
"""

from __future__ import annotations

import os

from django.core.cache import cache


def client_ip(request) -> str:
    """Best-effort client IP.

    Forwarded headers are only trusted when SWEEFT_TRUST_PROXY=1, and then the
    **last** hop is used (the value appended by the nearest trusted proxy), not
    the first hop, which a client can forge.
    """
    if os.getenv("SWEEFT_TRUST_PROXY", "") == "1":
        forwarded = request.META.get("HTTP_X_FORWARDED_FOR", "")
        if forwarded:
            return forwarded.split(",")[-1].strip()
    return request.META.get("REMOTE_ADDR", "unknown")


def is_rate_limited(scope: str, request, seconds: int) -> bool:
    """True when this client already hit the scope within `seconds`."""
    key = f"sweeft:ratelimit:{scope}:{client_ip(request)}"
    if cache.get(key):
        return True
    cache.set(key, 1, seconds)
    return False
