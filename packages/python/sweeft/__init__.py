"""Reusable Sweeft clients for other builders.

- `SweeftClient`: typed reads over the public `/api/v1` REST API.
- Release/refund message builders matching the Vault's on-chain format
  (byte-identical to what QoreX signs).
- Pure `evaluate_mandate` policy check (no Django needed) for AI-agent
  spending caps.
"""

from .client import SweeftClient
from .mandate import Mandate, evaluate_mandate
from .messages import release_message, refund_message, signing_payload

__all__ = [
    "SweeftClient",
    "Mandate",
    "evaluate_mandate",
    "release_message",
    "refund_message",
    "signing_payload",
]
__version__ = "0.1.0"
