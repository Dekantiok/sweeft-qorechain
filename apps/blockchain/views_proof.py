"""Transaction and escrow proof pages — verify on-chain, in the browser.

Every key transaction is decoded into a human-readable proof: what the
contract enforced, which signature gate applies, and what a replay or tamper
would have done. No explorer dive needed.
"""

from __future__ import annotations

import json
import logging

import requests
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, render
from django.views.decorators.http import require_GET

from apps.blockchain.services.reads import RelayerError, escrow_state
from apps.escrow.models import Escrow
from integrations.qorechain.client import get_network

logger = logging.getLogger(__name__)


def _cosmos_tx(tx_hash: str) -> dict | None:
    network = get_network()
    url = f"{network.rest_url}/cosmos/tx/v1beta1/txs/{tx_hash}"
    try:
        response = requests.get(url, timeout=15)
        response.raise_for_status()
        return response.json()
    except requests.RequestException:
        return None


def _evm_tx(web3, tx_hash: str) -> dict | None:
    try:
        tx = web3.eth.get_transaction(tx_hash)
        receipt = web3.eth.get_transaction_receipt(tx_hash)
        if not tx or not receipt:
            return None
        return {
            "hash": tx_hash,
            "from": tx.get("from"),
            "to": tx.get("to"),
            "value": tx.get("value"),
            "input": tx.get("input", "0x"),
            "block": receipt["blockNumber"],
            "status": int(receipt["status"]),
            "gas_used": int(receipt["gasUsed"]),
            "gas_limit": int(tx["gas"]),
        }
    except Exception:
        return None


def _tier_for(payload: dict) -> dict:
    """Map a Cosmos tx payload to Sweeft's honest tier labels."""
    if not payload:
        return {"tier": "unknown", "verified": False, "label": "Could not fetch the native-lane record."}
    tier = payload.get("tx_response", {}).get("security", {}).get("tier") or "unknown"
    labels = {
        "pqc": "Post-quantum (ML-DSA-87 hybrid) — the chain verified the signature layer",
        "enrollment": "Key enrollment — registers the account's ML-DSA-87 key (classical-signed, bootstrap-exempt)",
        "shake": "Native lane without an ML-DSA-87 layer",
        "classical": "EVM lane — secp256k1 only. Settlement safety comes from the contract's on-chain pqcVerify, not the tx signature.",
    }
    events = payload.get("tx_response", {}).get("events", [])
    verified = any(
        e.get("type") == "pqc_hybrid_verify"
        and any(a.get("key") == "status" and a.get("value") == "verified" for a in e.get("attributes", []))
        for e in events
    )
    return {"tier": tier, "verified": verified, "label": labels.get(tier, tier)}


@require_GET
def tx_proof(request, tx_hash: str):
    """Decode any transaction (native or EVM) into a human proof."""
    network = get_network()
    cosmos = _cosmos_tx(tx_hash)

    evm = None
    evm_error = None
    if cosmos is None:
        from web3 import Web3

        w3 = Web3(Web3.HTTPProvider(network.evm_rpc_url))
        evm = _evm_tx(w3, tx_hash)

    tier_info = _tier_for(cosmos) if cosmos else None

    # Link to a Sweeft escrow if this tx is in our projection.
    escrow = (
        Escrow.objects.filter(
            create_tx__iexact=tx_hash
        )
        .union(Escrow.objects.filter(fund_tx__iexact=tx_hash))
        .union(Escrow.objects.filter(release_tx__iexact=tx_hash))
        .union(Escrow.objects.filter(refund_tx__iexact=tx_hash))
        .first()
    )

    return render(
        request,
        "blockchain/tx_proof.html",
        {
            "tx_hash": tx_hash,
            "cosmos": cosmos,
            "evm": evm,
            "tier": tier_info,
            "escrow": escrow,
            "network": network,
            "evm_error": evm_error,
        },
    )


@require_GET
def verify_tx_page(request):
    """Public PQ verification: enter a Diana tx hash, verify live."""
    tx_hash = (request.GET.get("tx") or "").strip()
    result = None
    if tx_hash:
        from apps.blockchain.services.verify import verify_transaction
        result = verify_transaction(tx_hash)
    return render(request, "blockchain/verify.html", {"tx_hash": tx_hash, "result": result})


@require_GET
def escrow_proof(request, escrow_id: int):
    """The full PQ gate story for one escrow, read live from the chain."""
    escrow = get_object_or_404(
        Escrow.objects.select_related("order", "order__listing", "buyer", "seller"), on_chain_id=escrow_id
    )
    network = get_network()

    live = None
    live_error = None
    try:
        live = escrow_state(escrow_id)
    except Exception as exc:  # pragma: no cover - RPC hiccup path
        live_error = str(exc)

    pqc_status = None
    try:
        from integrations.qorechain.pqc import get_pqc_account_status

        pqc_status = get_pqc_account_status(escrow.buyer.qor_address or escrow.buyer.evm_address)
    except Exception:
        pqc_status = None

    return render(
        request,
        "blockchain/escrow_proof.html",
        {
            "escrow": escrow,
            "live": live,
            "live_error": live_error,
            "pqc_status": pqc_status,
            "network": network,
        },
    )


def drill_page(request):
    """Live Q-Day drill: keeper attack attempts and their on-chain refusals."""
    attacks = [
        {"name": "Release with a wrong ML-DSA-87 key", "response": "refused (status 0)", "tx": ""},
        {"name": "Release with a tampered amount", "response": "refused (status 0)", "tx": ""},
        {
            "name": "Carrier attestation by a non-carrier",
            "response": "refused (status 0)",
            "tx": "0x531f3ba7561f669e0480f7124cebbe5a41425a998282e48d4618eb8cd92d0a66",
        },
    ]
    return render(
        request,
        "blockchain/drill.html",
        {"attacks": attacks, "network": get_network()},
    )


def security_page(request):
    """Who can move money — every gate with its on-chain proof."""
    import os

    from integrations.qorechain.pqc import is_pqc_registered

    vault_address = os.getenv("SWEEFT_VAULT_ADDRESS", "")
    board_address = os.getenv("SWEEFT_DISPUTE_BOARD_ADDRESS", "")
    network = get_network()

    gates = [
        {
            "action": "Release escrow to seller",
            "who": "Buyer (guardian) — ML-DSA-87 signature",
            "mechanism": "SweeftVault.release() verifies the buyer's signature against the key registered on chain (pqcKeyStatus → pqcVerify).",
            "anti_replay": "Per-escrow nonce in the signed message (qorechain-msg-v1|…|nonce=…) — a used signature can never settle twice.",
            "evidence": "testnet attack sims: wrong-key and tampered-amount signatures both revert",
        },
        {
            "action": "Refund after deadline",
            "who": "Buyer — same ML-DSA-87 gate",
            "mechanism": "refundAfterDeadline() with the refund-tagged message; blocked once a verifier attests.",
            "anti_replay": "Same per-escrow nonce.",
            "evidence": "deadline path tested in Foundry (deadline, attest-blocked refund)",
        },
        {
            "action": "Carrier delivery attestation",
            "who": "Registered carrier (ML-DSA-87)",
            "mechanism": "attestCarrierEvidence() verifies the carrier's signature over the canonical tracking payload on-chain; carrier account must have a registered proven key.",
            "anti_replay": "Payload hash is bound to the escrow id and event timestamps.",
            "evidence": "Demo Carrier attested on Diana (see e2e_logistics.py)",
        },
        {
            "action": "Oracle attestation",
            "who": "DAO-approved verifier (registry)",
            "mechanism": "SweeftOracleRegistry is owned by SweeftDAO2; the vault checks isVerifier before marking evidence.",
            "anti_replay": "Attestation flips evidenceAttested — refund path closes.",
            "evidence": "registry ownership migrated via on-chain DAO proposal",
        },
        {
            "action": "Dispute settlement",
            "who": "Board contract (staked resolvers)",
            "mechanism": "Only the board may call resolveDispute; it needs a 2-of-3 resolver majority (v6: random panel from the staked pool, 5-resolver appeal). Stakes (≥20 QOR, v6: +100% of escrow) lock while serving.",
            "anti_replay": "Disputed status is terminal for the normal paths.",
            "evidence": "v5 dispute E2E settled on Diana; resolvers claimed their 10%-of-fee rewards (v6 pays a fixed bond fee — v6 live with two PQ releases, no dispute run yet)",
        },
        {
            "action": "Governance changes",
            "who": "SweeftDAO2 — stake-weighted (v6: QOR escrowed per vote, locked until final; v5 live: one wallet, one vote), allowlisted targets",
            "mechanism": "Calls are restricted to the oracle registry, vault and dispute board; params cannot be smuggled to arbitrary addresses.",
            "anti_replay": "Proposals are single-execution; description hash binds the call.",
            "evidence": "registry ownership migrated from DAO v1 by executed proposal",
        },
        {
            "action": "EVM spending",
            "who": "Owner's own signed window",
            "mechanism": "Scoped EVM windows (blocks / txs / value / targets), opened hybrid-signed; a stolen classical key is limited to the window budget.",
            "anti_replay": "Window nonce / expiry on chain.",
            "evidence": "deployer + buyer + seller + resolver windows shown in docs/deployments.md",
        },
    ]

    try:
        from apps.blockchain.services.reads import relayer_health

        relayer = relayer_health()
    except Exception:  # status page must render even if the relayer is unreachable
        relayer = {"configured": False, "warnings": ["relayer health check failed"], "window": None}

    return render(
        request,
        "blockchain/security.html",
        {
            "gates": gates,
            "vault_address": vault_address,
            "board_address": board_address,
            "network": network,
            "escrow_count": Escrow.objects.count(),
            "relayer": relayer,
        },
    )
