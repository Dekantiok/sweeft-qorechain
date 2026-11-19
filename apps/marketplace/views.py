"""Marketplace views — discovery over the indexed on-chain listings."""

from __future__ import annotations

from django.db.models import Q
from django.shortcuts import get_object_or_404, render

from .models import Category, Listing


def home(request):
    recent = Listing.objects.filter(status=Listing.Status.ACTIVE).select_related("seller", "category")[:6]
    return render(request, "marketplace/home.html", {"recent_listings": recent})


def listing_list(request):
    listings = Listing.objects.select_related("seller", "category")

    query = request.GET.get("q", "").strip()
    category = request.GET.get("category", "").strip()
    status = request.GET.get("status", "active").strip()

    if query:
        listings = listings.filter(Q(title__icontains=query) | Q(description__icontains=query))
    if category:
        listings = listings.filter(category__slug=category)
    if status and status != "all":
        listings = listings.filter(status=status)

    return render(
        request,
        "marketplace/list.html",
        {
            "listings": listings,
            "categories": Category.objects.all(),
            "query": query,
            "active_category": category,
            "active_status": status,
        },
    )


def listing_detail(request, listing_id: int):
    listing = get_object_or_404(
        Listing.objects.select_related("seller", "category"), on_chain_id=listing_id
    )
    import os

    return render(
        request,
        "marketplace/detail.html",
        {
            "listing": listing,
            "marketplace_address": os.getenv("SWEEFT_MARKETPLACE_ADDRESS", ""),
        },
    )
