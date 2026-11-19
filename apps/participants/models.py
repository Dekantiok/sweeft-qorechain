"""Participants — profiles, roles, and wallet associations."""

from __future__ import annotations

from django.conf import settings
from django.db import models


class Participant(models.Model):
    """A Sweeft user linked to their QoreChain account.

    The qor1 (bech32) and 0x (EVM) forms are the same account on QoreChain.
    Wallet linking is proven by a signature; only this record is authoritative
    for which wallet may act as buyer/seller.
    """

    class Role(models.TextChoices):
        BUYER = "buyer", "Buyer"
        SELLER = "seller", "Seller"
        BOTH = "both", "Buyer & Seller"
        VERIFIER = "verifier", "Oracle Verifier"

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="participant",
        null=True,
        blank=True,
        help_text="Django login; indexer-managed chain accounts may have none",
    )
    display_name = models.CharField(max_length=120)
    role = models.CharField(max_length=16, choices=Role.choices, default=Role.BUYER)

    # QoreChain account (both encodings of the same 20 bytes)
    qor_address = models.CharField(max_length=90, unique=True, null=True, blank=True)
    evm_address = models.CharField(max_length=42, unique=True, null=True, blank=True)

    wallet_linked_at = models.DateTimeField(null=True, blank=True)
    wallet_link_nonce = models.CharField(max_length=64, blank=True, default="")

    # PQC registration state (mirrors the chain; refreshed on read)
    pqc_key_registered = models.BooleanField(default=False)
    pqc_checked_at = models.DateTimeField(null=True, blank=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self) -> str:
        return f"{self.display_name} ({self.role})"

    @property
    def is_wallet_linked(self) -> bool:
        return bool(self.qor_address or self.evm_address)
