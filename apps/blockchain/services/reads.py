"""Chain reads - read-only helpers (no signing keys, no transaction submission).

Split from :mod:`apps.blockchain.services.relayer` so read paths (escrow
state, board parameters, verifier checks) can be used by views, the API and
AI tools without pulling in the key-holding submission code. ``relayer``
re-exports these names for backwards compatibility.
"""

from __future__ import annotations

import logging

from web3 import Web3

from integrations.qorechain.client import get_evm_client, get_network
from integrations.qorechain.contracts import artifact_path
from integrations.qorechain.contracts_base import load_abi, make_contract

logger = logging.getLogger(__name__)


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


def _escrow_dict(vault, w3, escrow_id: int) -> dict:
    """Read an escrow as a name-keyed dict (robust to struct field order).

    Uses the ABI output component names rather than fixed indices, so a future
    struct change cannot silently misalign the mapping (N-12).
    """
    fn = vault.functions.getEscrow(escrow_id)
    values = fn.call()
    components = fn.abi["outputs"][0].get("components")
    if components:
        return {c["name"]: v for c, v in zip(components, values)}
    # Fallback: positional (should not happen with the current ABI).
    return {
        "buyer": values[0],
        "seller": values[1],
        "amount": values[2],
        "status": values[5],
        "delivered": values[6],
        "fulfilledConfirmed": values[7],
        "evidenceAttested": values[8],
        "released": values[9],
        "verifier": values[10],
        "logisticsPartner": values[11],
        "logisticsAmount": values[12],
        "carrierAttested": values[13],
        "carrierStatus": values[19] if len(values) > 19 else "",
        "verifierAttestations": values[21] if len(values) > 21 else 0,
        "carrierDelivered": values[22] if len(values) > 22 else False,
    }


def escrow_state(escrow_id: int) -> dict:
    """Read one escrow directly from the chain (the source of truth)."""
    w3 = get_evm_client()
    vault = _vault_contract(w3)
    e = _escrow_dict(vault, w3, escrow_id)
    return {
        "escrow_id": escrow_id,
        "buyer": e["buyer"],
        "seller": e["seller"],
        "amount_wei": int(e["amount"]),
        "delivery_deadline": int(e["deliveryDeadline"]),
        "status": int(e["status"]),
        "delivered": e["delivered"],
        "confirmed": e["fulfilledConfirmed"],
        "attested": e["evidenceAttested"],
        "released": e["released"],
        "verifier": e["verifier"],
        "logistics_partner": e["logisticsPartner"],
        "logistics_amount": int(e["logisticsAmount"]),
        "carrier_attested": e["carrierAttested"],
        "carrier_delivered": e.get("carrierDelivered", False),
        "carrier_status": e.get("carrierStatus", ""),
        "verifier_attestations": int(e.get("verifierAttestations", 0)),
        "release_eligible": vault.functions.isReleaseEligible(escrow_id).call(),
        "refundable": vault.functions.isRefundable(escrow_id).call(),
        # v5/v6: nonce is per-escrow, so parallel escrows stay independent.
        "pqc_nonce": int(vault.functions.escrowNonce(escrow_id).call()),
    }


def vault_credits(address: str) -> int:
    """Withdrawable credits held by one account in the Vault (wei)."""
    if not address:
        return 0
    w3 = get_evm_client()
    vault = _vault_contract(w3)
    return int(vault.functions.credits(w3.to_checksum_address(address)).call())


def stake_position(address: str) -> dict:
    """Live resolver stake position: amount, cooldown, panel lock (wei/secs)."""
    if not address:
        return {"stake_wei": 0, "unstake_available_at": 0, "locked_until": 0}
    import os

    from integrations.qorechain.contracts_base import load_abi, make_contract

    w3 = get_evm_client()
    board_address = os.getenv("SWEEFT_DISPUTE_BOARD_ADDRESS", "")
    if not board_address:
        raise RelayerError("SWEEFT_DISPUTE_BOARD_ADDRESS is not configured")
    abi = load_abi(artifact_path("SweeftDisputeBoard"))
    board = make_contract(w3, board_address, abi)
    checksum = w3.to_checksum_address(address)
    return {
        "stake_wei": int(board.functions.stakeOf(checksum).call()),
        "unstake_available_at": int(board.functions.unstakeAvailableAt(checksum).call()),
        "locked_until": int(board.functions.lockedUntil(checksum).call()),
    }


def board_state() -> dict:
    """Read the dispute board's parameters and pool directly from the chain.

    Cached for 30s in Django's cache: the governor page calls this on every
    render and 8 sequential eth_calls against the public RPC take >10s.
    Board parameters change rarely (DAO proposals), so a short TTL is fine.
    """
    from django.core.cache import cache

    cached = cache.get("sweeft:board_state")
    if cached:
        return cached

    import json
    import os

    from integrations.qorechain.contracts_base import load_abi, make_contract

    w3 = get_evm_client()
    address = os.getenv("SWEEFT_DISPUTE_BOARD_ADDRESS", "")
    if not address:
        raise RelayerError("SWEEFT_DISPUTE_BOARD_ADDRESS is not configured")
    abi = load_abi(artifact_path("SweeftDisputeBoard"))
    board = make_contract(w3, address, abi)
    state = {
        "address": w3.to_checksum_address(address),
        "min_stake_wei": int(board.functions.minStake().call()),
        "reward_pool_wei": int(board.functions.rewardPool().call()),
        "pool_size": int(board.functions.poolSize().call()),
        "join_window": int(board.functions.joinWindow().call()),
        "voting_period": int(board.functions.votingPeriod().call()),
        "appeal_window": int(board.functions.appealWindow().call()),
        "unstake_cooldown": int(board.functions.unstakeCooldown().call()),
        "dispute_count": int(board.functions.disputeCount().call()),
    }
    cache.set("sweeft:board_state", state, 30)
    return state


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


def relayer_health() -> dict:
    """Read-only health of the project relayer (gas payer for signed calls).

    Shows the relayer's EVM balance and scoped-window headroom so a dying
    window (which would silently queue releases/refunds) is visible on the
    status page instead of discovered by users. Never signs anything; when
    the relayer is not configured it reports that plainly.
    """
    from django.core.cache import cache

    cached = cache.get("sweeft:relayer_health")
    if cached:
        return cached

    import os

    health: dict = {"configured": False, "address": None, "balance_qor": None,
                    "window": None, "warnings": [], "checked_at": None}
    if not os.getenv("RELAYER_MNEMONIC"):
        health["warnings"].append("RELAYER_MNEMONIC is not set — releases/refunds cannot be relayed")
        cache.set("sweeft:relayer_health", health, 30)
        return health

    from integrations.qorechain.window import evm_window_status, relayer_account

    try:
        account = relayer_account()
    except Exception as exc:
        health["warnings"].append(f"relayer account unavailable: {exc}")
        cache.set("sweeft:relayer_health", health, 30)
        return health

    health["configured"] = True
    health["address"] = account.evm
    try:
        w3 = get_evm_client()
        balance_wei = w3.eth.get_balance(w3.to_checksum_address(account.evm))
        health["balance_qor"] = int(balance_wei) / 1e18
        if health["balance_qor"] < 0.05:
            health["warnings"].append("relayer balance is low — top up testnet funds")
    except Exception as exc:
        health["warnings"].append(f"balance check failed: {exc}")

    try:
        window = evm_window_status(account.cosmos)
    except Exception as exc:
        window = None
        health["warnings"].append(f"window check failed: {exc}")
    health["window"] = window
    if not window or not window.get("live"):
        health["warnings"].append("no live EVM window — the next relay will open one (slow first submission)")
    elif int(window.get("remaining_txs", 0)) < 10:
        health["warnings"].append("EVM window nearly exhausted — it will be reopened on the next relay")

    from django.utils import timezone

    health["checked_at"] = timezone.now().isoformat()
    cache.set("sweeft:relayer_health", health, 30)
    return health


def carrier_nonce(carrier_evm: str, escrow_id: int) -> int:
    """Current per-(carrier, escrow) nonce for a v6 attestation binding (N-6)."""
    w3 = get_evm_client()
    vault = _vault_contract(w3)
    return int(vault.functions.carrierNonce(w3.to_checksum_address(carrier_evm), int(escrow_id)).call())
