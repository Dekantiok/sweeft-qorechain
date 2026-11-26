"""Pure mandate-cap evaluation for AI-agent spending (no Django needed).

Mirrors the policy enforced by the Sweeft app (per-transaction and rolling
daily caps). The on-chain window is always the hard cap; this is the
off-chain policy layer.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Mandate:
    per_tx_limit_uqor: int
    daily_limit_uqor: int
    daily_spent_uqor: int = 0
    active: bool = True
    expired: bool = False


def evaluate_mandate(mandate: Mandate | None, amount_uqor: int) -> dict:
    """True/False decision with a reason. Amounts in uqor."""
    if mandate is None or not mandate.active:
        return {"within_caps": False, "reason": "no active mandate"}
    if mandate.expired:
        return {"within_caps": False, "reason": "mandate expired"}
    if amount_uqor < 0:
        return {"within_caps": False, "reason": "negative amount"}
    if amount_uqor > mandate.per_tx_limit_uqor:
        return {
            "within_caps": False,
            "reason": f"amount {amount_uqor} exceeds per-tx cap {mandate.per_tx_limit_uqor}",
        }
    if mandate.daily_spent_uqor + amount_uqor > mandate.daily_limit_uqor:
        return {
            "within_caps": False,
            "reason": f"daily cap reached ({mandate.daily_spent_uqor}+{amount_uqor} > {mandate.daily_limit_uqor})",
        }
    return {"within_caps": True, "reason": "within caps"}
