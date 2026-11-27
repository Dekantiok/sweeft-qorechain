"""Project middleware."""

from __future__ import annotations

import secrets

from django.conf import settings


class NoCacheHTMLMiddleware:
    """HTML pages must never be served stale after a deploy.

    Wallet state lives in the session, so caching HTML would show visitors
    (and judges) the previous version of the site indefinitely. Static files
    stay cached, but hashed filenames make them safe (see production.py).
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)
        content_type = response.get("Content-Type", "")
        if "text/html" in content_type:
            response["Cache-Control"] = "no-cache, no-store, must-revalidate"
        return response


class ContentSecurityPolicyMiddleware:
    """Attach a Content-Security-Policy header when one is configured.

    A fresh per-request nonce is exposed to templates as ``csp_nonce`` and
    substituted for ``{nonce}`` in the configured policy, so inline scripts can
    be allowed individually without falling back to ``'unsafe-inline'``.
    """

    def __init__(self, get_response):
        self.get_response = get_response
        self.policy = getattr(settings, "CONTENT_SECURITY_POLICY", "")

    def __call__(self, request):
        nonce = secrets.token_urlsafe(18)
        request.csp_nonce = nonce
        response = self.get_response(request)
        if self.policy and "Content-Security-Policy" not in response:
            response["Content-Security-Policy"] = self.policy.replace("{nonce}", nonce)
        return response
