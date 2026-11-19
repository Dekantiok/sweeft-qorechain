"""PQC read helpers — account key status and transaction signature tiers.

Read-only. Verification of signatures happens on-chain in the contracts; this
module exists for dashboards, guards, and the AI agent's pre-flight checks.
"""

from __future__ import annotations

import requests

from .client import get_network


def get_pqc_account_status(address: str) -> dict:
    """Read an account's ML-DSA-87 key record from the REST API.

    Returns the raw REST payload:
      { address, public_key, algorithm_id, algorithm_name, ecdsa_pubkey,
        key_type, created_at_height, possession_proven, ... }
    """
    network = get_network()
    url = f"{network.rest_url}/qorechain/pqc/v1/account/{address}"
    response = requests.get(url, timeout=15)
    response.raise_for_status()
    return response.json()


def is_pqc_registered(address: str) -> bool:
    """True when the account has a registered ML-DSA-87 key."""
    try:
        data = get_pqc_account_status(address)
    except requests.RequestException:
        return False
    return bool(data.get("found")) and bool(data.get("account", {}).get("public_key"))


def get_transaction_pqc_tier(tx_hash: str) -> dict:
    """Read the signature tier of a transaction from the REST API.

    The chain labels transactions: 'pqc' (hybrid), 'enrollment', 'shake'
    (native without ML-DSA-87), or 'classical' (EVM lane).
    """
    network = get_network()
    url = f"{network.rest_url}/cosmos/tx/v1beta1/txs/{tx_hash}"
    response = requests.get(url, timeout=15)
    response.raise_for_status()
    payload = response.json()
    events = payload.get("tx_response", {}).get("events", [])
    verified = any(
        e.get("type") == "pqc_hybrid_verify"
        and any(a.get("key") == "status" and a.get("value") == "verified" for a in e.get("attributes", []))
        for e in events
    )
    return {"tx_hash": tx_hash, "hybrid_verified": verified, "raw": payload}
