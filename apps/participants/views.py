"""Dashboard — activity overview for the demo accounts."""

from __future__ import annotations

from django.shortcuts import render

from apps.escrow.models import Escrow
from apps.marketplace.models import Listing
from apps.oracle.models import FulfilmentEvidence


def dashboard(request):
    address = request.GET.get("address", "").strip()

    escrows = Escrow.objects.select_related("buyer", "seller", "order").order_by("-created_at")
    listings = Listing.objects.select_related("seller").order_by("-created_at")
    evidence = FulfilmentEvidence.objects.select_related("escrow", "submitted_by").order_by("-submitted_at")

    if address:
        escrows = escrows.filter(buyer__evm_address__iexact=address) | escrows.filter(
            seller__evm_address__iexact=address
        )
        listings = listings.filter(seller__evm_address__iexact=address)

    context = {
        "escrows": escrows[:50],
        "listings": listings[:50],
        "evidence": evidence[:50],
        "escrow_count": escrows.count(),
        "listing_count": listings.count(),
    }
    return render(request, "dashboard/index.html", context)
