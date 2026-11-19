"""Native-lane operations: PQ key registration and scoped EVM windows.

Used by the relayer and management tooling. The server-side relayer never
handles *user* keys — these helpers only manage the project's own testnet
relayer/deployer account (testnet only).
"""

from __future__ import annotations

import os

import httpx

from .client import get_network


def _qorsdk():
    import qorsdk  # imported lazily so Django can boot without the SDK installed

    return qorsdk


def account_info(address: str) -> dict | None:
    """Account number/sequence, or None when the account does not exist yet."""
    network = get_network()
    response = httpx.get(f"{network.rest_url}/cosmos/auth/v1beta1/accounts/{address}", timeout=20)
    if response.status_code == 404:
        return None
    response.raise_for_status()
    data = response.json()["account"]
    base = data.get("base_account", data)
    return {"account_number": int(base["account_number"]), "sequence": int(base["sequence"])}


def pqc_status(address: str) -> dict:
    network = get_network()
    qorsdk = _qorsdk()
    return qorsdk.fetch_pqc_status(network.rest_url, address)


def evm_window_status(address: str) -> dict | None:
    """The account's EVM window, or None when none is stored."""
    network = get_network()
    response = httpx.get(f"{network.rest_url}/qorechain/pqc/v1/evm_window/{address}", timeout=20)
    if response.status_code != 200:
        return None
    payload = response.json()
    return payload if payload.get("found") else None


def relayer_account():
    """Derive the relayer unified account from environment configuration."""
    qorsdk = _qorsdk()
    mnemonic = os.getenv("RELAYER_MNEMONIC") or os.getenv("SWEEFT_DEPLOYER_MNEMONIC", "")
    if not mnemonic:
        raise RuntimeError("RELAYER_MNEMONIC or SWEEFT_DEPLOYER_MNEMONIC must be set")
    return qorsdk.derive_unified_account(mnemonic.strip())


def relayer_private_key_hex() -> str:
    return relayer_account().private_key_hex


def ensure_relayer_window(*, blocks: int = 4_000, max_txs: int = 160, max_value: int = 20_000_000) -> dict:
    """Open a scoped EVM window for the relayer unless a live one has headroom."""
    qorsdk = _qorsdk()
    network = get_network()
    account = relayer_account()

    status = evm_window_status(account.cosmos)
    if status and status.get("live") and int(status.get("remaining_txs", 0)) >= 10:
        return {"opened": False, "window": status}

    info = account_info(account.cosmos)
    if info is None:
        raise RuntimeError(f"relayer {account.cosmos} is not funded on chain")

    open_msg = qorsdk.msg.pqc.open_evm_window(
        sender=account.cosmos, blocks=blocks, max_txs=max_txs, max_value=str(max_value)
    )

    def build(version):
        return qorsdk.sign_hybrid_eth(
            account=account,
            chain_id=network.chain_id,
            account_number=info["account_number"],
            messages=[open_msg],
            fee={"amount": [{"denom": "uqor", "amount": "50000"}], "gas": "500000"},
            sequence=info["sequence"],
            sign_bytes_version=version,
        )

    response = qorsdk.hybrid_sign_and_broadcast(build, chain_id=network.chain_id, rest_url=network.rest_url)
    tx_response = response.get("tx_response") or response
    if int(tx_response.get("code", 0)) != 0:
        raise RuntimeError(f"window open rejected: {tx_response.get('raw_log', '')[:200]}")
    return {"opened": True, "tx_hash": tx_response.get("txhash", "?")}
