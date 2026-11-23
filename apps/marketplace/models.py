"""Marketplace — listings projected from on-chain state.

The chain (SweeftMarketplace.sol) is the source of truth for listings: seller,
price, status and purchases. These models are a searchable projection rebuilt
by the event indexer; metadata (title, description, images) is stored here and
hash-anchored on-chain.
"""

from __future__ import annotations

from django.db import models

from apps.participants.models import Participant


class Category(models.Model):
    name = models.CharField(max_length=80, unique=True)
    slug = models.SlugField(max_length=80, unique=True)
    description = models.TextField(blank=True)

    class Meta:
        verbose_name_plural = "categories"
        ordering = ["name"]

    def __str__(self) -> str:
        return self.name


class Listing(models.Model):
    """Projection of an on-chain listing."""

    class Status(models.TextChoices):
        ACTIVE = "active", "Active"
        SOLD = "sold", "Sold"
        CANCELLED = "cancelled", "Cancelled"

    on_chain_id = models.PositiveBigIntegerField(unique=True, help_text="uint256 listing id on SweeftMarketplace")
    seller = models.ForeignKey(Participant, on_delete=models.PROTECT, related_name="listings")
    category = models.ForeignKey(Category, on_delete=models.SET_NULL, null=True, blank=True, related_name="listings")

    title = models.CharField(max_length=200)
    description = models.TextField(help_text="Plain text; rendered safely in templates")
    price_uqor = models.DecimalField(
        max_digits=30, decimal_places=0, help_text="Price in uqor (1 QOR = 10^6 uqor) — matches on-chain price"
    )
    quantity = models.PositiveIntegerField(default=1)

    status = models.CharField(max_length=16, choices=Status.choices, default=Status.ACTIVE)

    # Hash-anchored metadata (Django-hosted; IPFS adapter later)
    metadata_uri = models.URLField(max_length=500, blank=True)
    metadata_hash = models.CharField(max_length=66, blank=True, help_text="SHA-256 hex of the metadata JSON")

    # Logistics (v4) — physical listings carry a carrier allocation
    class DeliveryType(models.TextChoices):
        PHYSICAL = "physical", "Physical (carrier)"
        DIGITAL = "digital", "Digital"

    delivery_type = models.CharField(max_length=16, choices=DeliveryType.choices, default=DeliveryType.PHYSICAL)
    logistics_partner_address = models.CharField(max_length=42, blank=True)
    logistics_fee_uqor = models.DecimalField(max_digits=30, decimal_places=0, default=0)

    # Negotiation (AI agent can bargain against the floor; acceptance updates the price)
    floor_price_uqor = models.DecimalField(
        max_digits=30, decimal_places=0, default=0,
        help_text="Lowest price the seller will accept in negotiation (0 = no negotiation, fixed price)",
    )
    auto_accept_floor = models.BooleanField(default=False, help_text="Seller flips this on to auto-accept offers at/above the floor")

    created_tx = models.CharField(max_length=80, blank=True)
    created_block = models.PositiveBigIntegerField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["status", "-created_at"]),
            models.Index(fields=["seller", "status"]),
        ]

    def __str__(self) -> str:
        return f"#{self.on_chain_id} {self.title}"

    @property
    def price_qor(self) -> str:
        return f"{int(self.price_uqor) / 1_000_000:.6f}".rstrip("0").rstrip(".")


class ListingImage(models.Model):
    listing = models.ForeignKey(Listing, on_delete=models.CASCADE, related_name="images")
    image = models.ImageField(upload_to="listings/")
    position = models.PositiveSmallIntegerField(default=0)
    uploaded_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["position", "id"]


# Negotiation models live in a sibling module but belong to this app;
# import eagerly so migrations and the indexer can find them.
from .negotiation_models import Negotiation as Negotiation  # noqa: E402,F401
