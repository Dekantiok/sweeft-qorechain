"""Relayer — submits EVM-lane transactions paid for by the project.

User actions that are *authorized by signature* (escrow release/refund need the
buyer's ML-DSA-87 signature) are permissionless on-chain, so the relayer can
submit them without holding any user key. The relayer account is the project's
own testnet account; it pays gas and keeps a scoped EVM window open.
"""

from __future__ import annotations

import logging

from web3 import Web3

from integrations.qorechain.client import get_evm_client, get_network
from integrations.qorechain.contracts import artifact_path
from integrations.qorechain.contracts_base import load_abi, make_contract
from integrations.qorechain.window import ensure_relayer_window, relayer_private_key_hex

logger = logging.getLogger(__name__)

RELEASE_GAS = 8_000_000


class RelayerError(RuntimeError):
    pass


def _vault_contract(w3: Web3):
    network = get_network()
    import os

    address = os.getenv("SWEEFT_VAULT_ADDRESS", "")
    if not address:
        raise RelayerError("SWEEFT_VAULT_ADDRESS is not configured")
    abi = load_abi(artifact_path("SweeftVault"))
    return w3.eth.contract(address=w3.to_checksum_address(address), abi=abi)


def _send(w3: Web3, account, fn_call, *, value: int = 0, gas: int) -> dict:
    tx = fn_call.build_transaction(
        {
            "from": account.address,
            "value": value,
            "gas": gas,
            "gasPrice": w3.eth.gas_price,
            "nonce": w3.eth.get_transaction_count(account.address, "pending"),
            "chainId": get_network().evm_chain_id,
        }
    )
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
    if receipt.status != 1:
        raise RelayerError(f"transaction reverted: {tx_hash.hex()}")
    return {"tx_hash": tx_hash.hex(), "block": receipt.blockNumber, "gas_used": receipt.gasUsed}


def submit_release(escrow_id: int, signature: bytes) -> dict:
    """Relay `SweeftVault.release(escrowId, signature)`.

    The signature must be the buyer's ML-DSA-87 signature over the QoreSign
    payload for this escrow; the contract verifies it on-chain.
    """
    w3 = get_evm_client()
    account = w3.eth.account.from_key(relayer_private_key_hex())
    vault = _vault_contract(w3)
    ensure_relayer_window()
    logger.info("relaying release for escrow %s", escrow_id)
    return _send(w3, account, vault.functions.release(escrow_id, signature), gas=RELEASE_GAS)


def submit_refund(escrow_id: int, signature: bytes) -> dict:
    """Relay `SweeftVault.refundAfterDeadline(escrowId, signature)`."""
    w3 = get_evm_client()
    account = w3.eth.account.from_key(relayer_private_key_hex())
    vault = _vault_contract(w3)
    ensure_relayer_window()
    logger.info("relaying refund for escrow %s", escrow_id)
    return _send(w3, account, vault.functions.refundAfterDeadline(escrow_id, signature), gas=RELEASE_GAS)


def escrow_state(escrow_id: int) -> dict:
    """Read one escrow directly from the chain (the source of truth)."""
    w3 = get_evm_client()
    vault = _vault_contract(w3)
    escrow = vault.functions.getEscrow(escrow_id).call()
    return {
        "escrow_id": escrow_id,
        "buyer": escrow[0],
        "seller": escrow[1],
        "amount_wei": int(escrow[2]),
        "delivery_deadline": int(escrow[3]),
        "status": int(escrow[5]),
        "delivered": escrow[6],
        "confirmed": escrow[7],
        "attested": escrow[8],
        "released": escrow[9],
        "release_eligible": vault.functions.isReleaseEligible(escrow_id).call(),
        "refundable": vault.functions.isRefundable(escrow_id).call(),
        "pqc_nonce": vault.functions.pqcNonce(w3.to_checksum_address(escrow[0])).call(),
    }
