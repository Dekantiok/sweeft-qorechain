"""Project middleware."""

from __future__ import annotations

from django.conf import settings


class ContentSecurityPolicyMiddleware:
    """Attach a Content-Security-Policy header when one is configured.

    Django has no built-in CSP support; this keeps the policy declarative in
    settings while avoiding an extra dependency.
    """

    def __init__(self, get_response):
        self.get_response = get_response
        self.policy = getattr(settings, "CONTENT_SECURITY_POLICY", "")

    def __call__(self, request):
        response = self.get_response(request)
        if self.policy and "Content-Security-Policy" not in response:
            response["Content-Security-Policy"] = self.policy
        return response
