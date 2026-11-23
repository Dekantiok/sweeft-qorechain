"""Relayer — submits EVM-lane transactions paid for by the project.

User actions that are *authorized by signature* (escrow release/refund need the
buyer's ML-DSA-87 signature) are permissionless on-chain, so the relayer can
submit them without holding any user key. The relayer account is the project's
own testnet account; it pays gas and keeps a scoped EVM window open.
"""

from __future__ import annotations

import logging
import threading

from web3 import Web3

from integrations.qorechain.client import get_evm_client, get_network
from integrations.qorechain.contracts import artifact_path
from integrations.qorechain.contracts_base import load_abi, make_contract
from integrations.qorechain.window import ensure_relayer_window, relayer_private_key_hex

logger = logging.getLogger(__name__)

#: Fallback gas cap when estimation is unavailable.
RELEASE_GAS_FALLBACK = 2_000_000
#: ML-DSA-87 signatures are 4,627 bytes; anything else is malformed input.
ML_DSA_87_SIG_LEN = 4627
#: Serialize nonce reads/writes so concurrent relays don't collide.
_nonce_lock = threading.Lock()


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
        "verifier": escrow[10],
        "logistics_partner": escrow[11],
        "logistics_amount": int(escrow[12]),
        "carrier_attested": escrow[13],
        "carrier_status": escrow[19] if len(escrow) > 19 else "",
        "verifier_attestations": int(escrow[21]) if len(escrow) > 21 else 0,
        "release_eligible": vault.functions.isReleaseEligible(escrow_id).call(),
        "refundable": vault.functions.isRefundable(escrow_id).call(),
        # v5: nonce is per-escrow, so parallel escrows stay independent.
        "pqc_nonce": int(vault.functions.escrowNonce(escrow_id).call()),
    }


def board_state() -> dict:
    """Read the dispute board's parameters and pool directly from the chain."""
    import json
    import os

    from integrations.qorechain.contracts_base import load_abi, make_contract

    w3 = get_evm_client()
    address = os.getenv("SWEEFT_DISPUTE_BOARD_ADDRESS", "")
    if not address:
        raise RelayerError("SWEEFT_DISPUTE_BOARD_ADDRESS is not configured")
    abi = load_abi(artifact_path("SweeftDisputeBoard"))
    board = make_contract(w3, address, abi)
    return {
        "address": w3.to_checksum_address(address),
        "min_stake_wei": int(board.functions.minStake().call()),
        "reward_pool_wei": int(board.functions.rewardPool().call()),
        "voting_period": int(board.functions.votingPeriod().call()),
        "unstake_cooldown": int(board.functions.unstakeCooldown().call()),
        "dispute_count": int(board.functions.disputeCount().call()),
    }


def is_verifier(address: str) -> bool:
    """True when the address is an authorized oracle verifier on the registry."""
    import os

    from integrations.qorechain.contracts_base import load_abi, make_contract

    if not address:
        return False
    w3 = get_evm_client()
    registry_address = os.getenv("SWEEFT_ORACLE_REGISTRY_ADDRESS", "")
    if not registry_address:
        return False
    abi = load_abi(artifact_path("SweeftOracleRegistry"))
    registry = make_contract(w3, registry_address, abi)
    try:
        return bool(registry.functions.isVerifier(w3.to_checksum_address(address)).call())
    except Exception:
        return False


def carrier_nonce(carrier_evm: str) -> int:
    """Current single-use nonce for a carrier (v5 attestation binding)."""
    w3 = get_evm_client()
    vault = _vault_contract(w3)
    return int(vault.functions.carrierNonce(w3.to_checksum_address(carrier_evm)).call())


def attest_carrier_evidence(
    escrow_id: int,
    tracking_number: str,
    status: str,
    issued_at: int,
    signature: bytes,
) -> dict:
    """Submit the carrier's signed v5 attestation to the Vault (as the carrier).

    The vault rebuilds the canonical message from (carrier, escrowId, tracking,
    status, issuedAt, nonce) and verifies the ML-DSA-87 signature on-chain.
    """
    from apps.logistics.carriers import demo_carrier_keypair

    _, _, carrier_evm = demo_carrier_keypair()
    w3 = get_evm_client()
    from qorsdk import derive_unified_account

    import os

    mnemonic = os.getenv("SWEEFT_DEPLOYER_MNEMONIC", "")
    account = derive_unified_account(mnemonic, index=6)
    eth_account = w3.eth.account.from_key(account.private_key_hex)
    vault = _vault_contract(w3)
    ensure_relayer_window()  # opener for carrier too (best-effort)

    fn = vault.functions.attestCarrierEvidence(escrow_id, tracking_number, status, issued_at, signature)
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
