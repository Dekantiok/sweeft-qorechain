"""Sweeft AI views — natural-language commerce assistant."""

from __future__ import annotations

from django.shortcuts import render


def assistant(request):
    return render(request, "ai/index.html")
