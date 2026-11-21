"""Template context — exposes the connected wallet to every page."""

from __future__ import annotations


def wallet(request):
    account = request.session.get("wallet_account") or {}
    evm = account.get("evm", "")
    qor = account.get("qor", "")
    return {
        "wallet_account": evm,
        "wallet_qor": qor,
        "wallet_short": f"{evm[:6]}…{evm[-4:]}" if evm else "",
        "wallet_method": account.get("method", ""),
    }
