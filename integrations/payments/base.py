"""Payment provider interface.

A successful fiat payment is NOT an on-chain escrow deposit. Providers that
convert fiat must define custody, conversion, and reconciliation explicitly.
For this MVP, escrow funding is native QOR on QoreChain; this interface exists
so a future provider can be added without touching escrow business logic.
"""

from __future__ import annotations

from abc import ABC, abstractmethod


class PaymentProvider(ABC):
    @abstractmethod
    def create_payment(self, transaction) -> dict:
        """Initiate a payment for a commerce transaction."""

    @abstractmethod
    def verify_payment(self, reference: str) -> dict:
        """Verify a payment by provider reference."""

    @abstractmethod
    def process_refund(self, reference: str) -> dict:
        """Refund a payment by provider reference."""
