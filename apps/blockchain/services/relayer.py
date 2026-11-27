"""Relayer - submits EVM-lane transactions paid for by the project.

User actions that are *authorized by signature* (escrow release/refund need the
buyer's ML-DSA-87 signature) are permissionless on-chain, so the relayer can
submit them without holding any user key. The relayer account is the project's
own testnet account; it pays gas and keeps a scoped EVM window open.

Read-only helpers live in :mod:`apps.blockchain.services.reads` (no keys) and
are re-exported here for backwards compatibility.
"""

from __future__ import annotations

import logging
import threading

from web3 import Web3

from apps.blockchain.services.reads import (  # noqa: F401  (re-exported)
    RelayerError,
    _vault_contract,
    board_state,
    carrier_nonce,
    escrow_state,
    is_verifier,
    relayer_health,
    stake_position,
    vault_credits,
)
from integrations.qorechain.client import get_evm_client, get_network
from integrations.qorechain.window import ensure_relayer_window, relayer_private_key_hex

logger = logging.getLogger(__name__)

#: Fallback gas cap when estimation is unavailable.
RELEASE_GAS_FALLBACK = 2_000_000
#: ML-DSA-87 signatures are 4,627 bytes; anything else is malformed input.
ML_DSA_87_SIG_LEN = 4627
#: Serialize nonce reads/writes so concurrent relays don't collide.
_nonce_lock = threading.Lock()


def _valid_signature(signature: bytes) -> bool:
    return ML_DSA_87_SIG_LEN - 64 <= len(signature) <= ML_DSA_87_SIG_LEN + 64


def _send(w3: Web3, account, fn_call, *, value: int = 0) -> dict:
    """Simulate, estimate gas, then send — never burn gas on a doomed call."""
    call_args = {"from": account.address, "value": value}
    try:
        fn_call.call(call_args)
    except Exception as exc:  # simulation reverted: refuse before spending gas
        raise RelayerError(f"simulation reverted (transaction would fail): {str(exc)[:200]}")

    try:
        estimate = fn_call.estimate_gas(call_args)
        gas = int(estimate * 12 // 10)  # 20% headroom
    except Exception:
        gas = RELEASE_GAS_FALLBACK

    with _nonce_lock:
        nonce = w3.eth.get_transaction_count(account.address, "pending")
        tx = fn_call.build_transaction(
            {
                "from": account.address,
                "value": value,
                "gas": gas,
                "gasPrice": w3.eth.gas_price,
                "nonce": nonce,
                "chainId": get_network().evm_chain_id,
            }
        )
        signed = account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=90)
    if receipt.status != 1:
        raise RelayerError(f"transaction reverted: {tx_hash.hex()}")
    return {"tx_hash": tx_hash.hex(), "block": receipt.blockNumber, "gas_used": receipt.gasUsed}


def submit_release(escrow_id: int, signature: bytes) -> dict:
    """Relay `SweeftVault.release(escrowId, signature)`.

    The signature must be the buyer's ML-DSA-87 signature over the QoreSign
    payload for this escrow; the contract verifies it on-chain.
    """
    if not _valid_signature(signature):
        raise RelayerError("signature is not a plausible ML-DSA-87 signature")
    w3 = get_evm_client()
    account = w3.eth.account.from_key(relayer_private_key_hex())
    vault = _vault_contract(w3)
    ensure_relayer_window()
    logger.info("relaying release for escrow %s", escrow_id)
    return _send(w3, account, vault.functions.release(escrow_id, signature))


def submit_refund(escrow_id: int, signature: bytes) -> dict:
    """Relay `SweeftVault.refundAfterDeadline(escrowId, signature)`."""
    if not _valid_signature(signature):
        raise RelayerError("signature is not a plausible ML-DSA-87 signature")
    w3 = get_evm_client()
    account = w3.eth.account.from_key(relayer_private_key_hex())
    vault = _vault_contract(w3)
    ensure_relayer_window()
    logger.info("relaying refund for escrow %s", escrow_id)
    return _send(w3, account, vault.functions.refundAfterDeadline(escrow_id, signature))


def attest_carrier_evidence(
    escrow_id: int,
    tracking_number: str,
    status: str,
    issued_at: int,
    expires_at: int,
    evidence_hash: str,
    signature: bytes,
) -> dict:
    """Submit the carrier's signed v2 attestation to the Vault (as the carrier).

    The vault rebuilds the domain-separated message (chain, vault, carrier,
    provider, escrow, tracking hash, status, evidence, window, nonce) and
    verifies the ML-DSA-87 signature on-chain. The EVM transaction is signed
    by the carrier account itself — never the deployer (owner) key.
    """
    w3 = get_evm_client()
    from apps.logistics import carriers as carriers_module

    account = carriers_module.demo_carrier_account()
    carrier_evm = account.evm
    eth_account = w3.eth.account.from_key(account.private_key_hex)
    vault = _vault_contract(w3)
    ensure_relayer_window()  # opener for carrier too (best-effort)

    fn = vault.functions.attestCarrierEvidence(
        escrow_id, tracking_number, status, bytes.fromhex(evidence_hash), issued_at, expires_at, signature
    )
    tx = fn.build_transaction(
        {
            "from": eth_account.address,
            "value": 0,
            "gas": 1_000_000,
            "gasPrice": w3.eth.gas_price,
            "nonce": w3.eth.get_transaction_count(eth_account.address, "pending"),
            "chainId": get_network().evm_chain_id,
        }
    )
    signed = eth_account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
    if receipt.status != 1:
        raise RelayerError(f"carrier attestation reverted: {tx_hash.hex()}")
    return {"tx_hash": tx_hash.hex(), "block": receipt.blockNumber, "carrier": carrier_evm}
