#!/usr/bin/env python3
"""Sweeft — shared testnet helpers for scripts and tools.

Wraps the QoreChain Python SDK (qorsdk) and web3 for the operations the
project's scripts need: account derivation, native-lane PQ key registration,
scoped EVM windows, and EVM-lane transaction sending.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv

REPO_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(REPO_ROOT / ".env")
sys.path.insert(0, str(REPO_ROOT))

from qorsdk import (  # noqa: E402
    build_register_pqc_key,
    broadcast,
    derive_unified_account,
    fetch_pqc_status,
    generate_mnemonic,
    msg,
    sign_proof_of_possession,
)
from qorsdk.sign_eth import sign_classical_eth, sign_hybrid_eth  # noqa: E402
from qorsdk.tx import hybrid_sign_and_broadcast  # noqa: E402
from web3 import Web3  # noqa: E402

REST_URL = os.getenv("QORECHAIN_REST_URL", "https://api-testnet.qore.host")
EVM_RPC = os.getenv("QORECHAIN_EVM_RPC_URL", "https://evm-testnet.qore.host")
CHAIN_ID = os.getenv("QORECHAIN_CHAIN_ID", "qorechain-diana")
EVM_CHAIN_ID = int(os.getenv("QORECHAIN_EVM_CHAIN_ID", "9800"))
EXPLORER = os.getenv("QORECHAIN_EXPLORER_URL", "https://explore.qore.network")

# QoreSign message-signing-v1 domain prefix — the same bytes QoreX produces.
QORESIGN_MSG_PREFIX = "qorechain-msg-v1|"


def pqc_signing_payload(data: bytes, chain_id: str | None = None) -> bytes:
    """Build the exact bytes QoreX/QoreSign ML-DSA-87-signs (message-signing-v1)."""
    cid = chain_id or CHAIN_ID
    return QORESIGN_MSG_PREFIX.encode() + cid.encode() + b"|" + data


def release_message(vault: str, escrow_id: int, buyer: str, recipient: str, amount: int, nonce: int) -> bytes:
    """The human-readable release data — must match SweeftVault._releaseMessage."""
    return (
        f"sweeft-release-v1|vault={vault.lower()}|escrow={escrow_id}|buyer={buyer.lower()}"
        f"|recipient={recipient.lower()}|amount={amount}|nonce={nonce}"
    ).encode()


def refund_message(vault: str, escrow_id: int, buyer: str, recipient: str, amount: int, nonce: int) -> bytes:
    """The human-readable refund data — must match SweeftVault._refundMessage."""
    return (
        f"sweeft-refund-v1|vault={vault.lower()}|escrow={escrow_id}|buyer={buyer.lower()}"
        f"|recipient={recipient.lower()}|amount={amount}|nonce={nonce}"
    ).encode()

CONTRACTS = {
    "SweeftVault": "SWEEFT_VAULT_ADDRESS",
    "SweeftMarketplace": "SWEEFT_MARKETPLACE_ADDRESS",
    "SweeftOracleRegistry": "SWEEFT_ORACLE_REGISTRY_ADDRESS",
    "SweeftDAO": "SWEEFT_DAO_ADDRESS",
}


def die(message: str, code: int = 1) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(code)


def mnemonic() -> str:
    value = os.getenv("SWEEFT_DEPLOYER_MNEMONIC", "").strip()
    if not value:
        die("SWEEFT_DEPLOYER_MNEMONIC missing in .env — run tools/qor_account.py new")
    return value


def account(index: int = 0):
    """Derive a unified account from the stored mnemonic at ``index``."""
    return derive_unified_account(mnemonic(), index=index)


def get_w3() -> Web3:
    w3 = Web3(Web3.HTTPProvider(EVM_RPC))
    if not w3.is_connected():
        die(f"cannot reach {EVM_RPC}")
    return w3


def contract(w3: Web3, name: str):
    address = os.getenv(CONTRACTS[name], "")
    if not address:
        die(f"{CONTRACTS[name]} missing in .env")
    artifact = REPO_ROOT / "contracts" / "out" / f"{name}.sol" / f"{name}.json"
    abi = json.loads(artifact.read_text())["abi"]
    return w3.eth.contract(address=w3.to_checksum_address(address), abi=abi)


def contract_address(name: str) -> str:
    address = os.getenv(CONTRACTS[name], "")
    if not address:
        die(f"{CONTRACTS[name]} missing in .env")
    return address


# ---------------------------------------------------------------------------
# Native lane (accounts, registration)
# ---------------------------------------------------------------------------


def account_info(address: str) -> dict | None:
    response = httpx.get(f"{REST_URL}/cosmos/auth/v1beta1/accounts/{address}", timeout=20)
    if response.status_code == 404:
        return None
    response.raise_for_status()
    account_data = response.json()["account"]
    base = account_data.get("base_account", account_data)
    return {
        "account_number": int(base["account_number"]),
        "sequence": int(base["sequence"]),
    }


def balance_uqor(address: str) -> int:
    response = httpx.get(f"{REST_URL}/cosmos/bank/v1beta1/balances/{address}", timeout=20)
    response.raise_for_status()
    for entry in response.json().get("balances", []):
        if entry["denom"] == "uqor":
            return int(entry["amount"])
    return 0


def _check_broadcast(response, what: str) -> str:
    """Extract the tx hash from a broadcast response; fail on non-zero code."""
    tx_response = response.get("tx_response") or response
    code = int(tx_response.get("code", 0))
    tx_hash = tx_response.get("txhash", "?")
    if code != 0:
        raw = str(tx_response.get("raw_log", ""))[:300]
        die(f"{what} rejected (code {code}): {raw}")
    return tx_hash


def ensure_pqc_registered(unified) -> None:
    status = fetch_pqc_status(REST_URL, unified.cosmos)
    if status.get("registered"):
        return
    info = account_info(unified.cosmos)
    if info is None:
        die(f"{unified.cosmos} has no funds — fund it before registering")
    proof = sign_proof_of_possession(chain_id=CHAIN_ID, account=unified.cosmos, keypair=unified.pqc)
    register = build_register_pqc_key(
        sender=unified.cosmos,
        dilithium_pubkey=unified.pqc.public_key,
        ecdsa_pubkey=unified.public_key,
        key_type="hybrid",
        proof_of_possession=proof,
    )
    built = sign_classical_eth(
        account=unified,
        chain_id=CHAIN_ID,
        account_number=info["account_number"],
        messages=[register],
        fee={"amount": [{"denom": "uqor", "amount": "60000"}], "gas": "600000"},
        sequence=info["sequence"],
    )
    response = broadcast(REST_URL, built.tx_raw_bytes)
    tx_hash = _check_broadcast(response, f"PQ registration for {unified.cosmos}")
    print(f"    PQ key registered: {tx_hash}")


def window_status(address: str) -> dict | None:
    response = httpx.get(f"{REST_URL}/qorechain/pqc/v1/evm_window/{address}", timeout=20)
    if response.status_code != 200:
        return None
    payload = response.json()
    return payload if payload.get("found") else None


def ensure_evm_window(
    unified,
    *,
    blocks: int = 3_600,
    max_txs: int = 60,
    max_value: int = 10_000_000,
    min_txs: int = 10,
) -> None:
    """Open a scoped EVM window unless a live one with headroom already exists."""
    status = window_status(unified.cosmos)
    if status and status.get("live") and int(status.get("remaining_txs", 0)) >= min_txs:
        print(f"    window live: {status.get('remaining_txs')} txs left, "
              f"expires at height {status.get('expiry_height')}")
        return

    info = account_info(unified.cosmos)
    if info is None:
        die(f"{unified.cosmos} has no funds")
    open_msg = msg.pqc.open_evm_window(
        sender=unified.cosmos, blocks=blocks, max_txs=max_txs, max_value=str(max_value)
    )

    def build(version):
        return sign_hybrid_eth(
            account=unified,
            chain_id=CHAIN_ID,
            account_number=info["account_number"],
            messages=[open_msg],
            fee={"amount": [{"denom": "uqor", "amount": "50000"}], "gas": "500000"},
            sequence=info["sequence"],
            sign_bytes_version=version,
        )

    response = hybrid_sign_and_broadcast(build, chain_id=CHAIN_ID, rest_url=REST_URL)
    tx_hash = _check_broadcast(response, f"EVM window open for {unified.cosmos}")
    print(f"    EVM window opened: {tx_hash}")


# ---------------------------------------------------------------------------
# EVM lane
# ---------------------------------------------------------------------------


def send_evm(w3: Web3, unified, fn_call, *, value: int = 0, gas: int = 800_000) -> dict:
    """Sign and send one EVM-lane transaction; wait for the receipt."""
    eth_account = w3.eth.account.from_key(unified.private_key_hex)
    tx = fn_call.build_transaction(
        {
            "from": eth_account.address,
            "value": value,
            "gas": gas,
            "gasPrice": w3.eth.gas_price,
            "nonce": w3.eth.get_transaction_count(eth_account.address, "pending"),
            "chainId": EVM_CHAIN_ID,
        }
    )
    signed = eth_account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
    return {"hash": tx_hash.hex(), "status": receipt.status, "gas_used": receipt.gasUsed}


def send_evm_expect_success(w3: Web3, unified, fn_call, *, value: int = 0, gas: int = 800_000) -> dict:
    result = send_evm(w3, unified, fn_call, value=value, gas=gas)
    if result["status"] != 1:
        die(f"transaction reverted: {EXPLORER}/tx/{result['hash']}")
    return result


def transfer_qor(w3: Web3, sender_unified, to_address: str, amount_uqor: int, *, gas: int = 100_000) -> dict:
    """Send a plain QOR value transfer on the EVM lane."""
    eth_account = w3.eth.account.from_key(sender_unified.private_key_hex)
    tx = {
        "from": eth_account.address,
        "to": w3.to_checksum_address(to_address),
        "value": amount_uqor,
        "gas": gas,
        "gasPrice": w3.eth.gas_price,
        "nonce": w3.eth.get_transaction_count(eth_account.address, "pending"),
        "chainId": EVM_CHAIN_ID,
    }
    signed = eth_account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
    if receipt.status != 1:
        die(f"transfer reverted: {tx_hash.hex()}")
    return {"hash": tx_hash.hex(), "status": receipt.status}
