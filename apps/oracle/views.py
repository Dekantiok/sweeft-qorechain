"""Oracle views — fulfilment evidence review and PQ verifier attestations."""

from __future__ import annotations

import json
import logging
import time

from django.http import JsonResponse
from django.shortcuts import render
from django.views.decorators.http import require_GET, require_POST

from apps.blockchain.services.reads import is_verifier

from .models import FulfilmentEvidence

logger = logging.getLogger(__name__)

#: The vault pins every signature's expiry to issuedAt + this age.
MAX_ATTEST_AGE_SECONDS = 7 * 24 * 3600

# Indexed (DB) escrow state -> on-chain status int (0 None, 1 Funded,
# 2 Completed, 3 Cancelled, 4 Refunded, 5 Disputed). B-12: the page used to
# do one live chain read per evidence row (N reads, 30s+); it now uses the
# indexed mirror, which the indexer keeps in sync.
_DB_TO_CHAIN_STATUS = {
    "created": 0,
    "funded": 1,
    "fulfilled": 1,
    "delivered": 1,
    "release_eligible": 1,
    "completed": 2,
    "cancelled": 3,
    "refunded": 4,
    "disputed": 5,
}


def evidence_list(request):
    evidence = FulfilmentEvidence.objects.select_related(
        "escrow", "escrow__buyer", "escrow__seller", "submitted_by"
    ).order_by("-submitted_at")[:50]

    wallet = (request.session.get("wallet_account") or {}).get("evm", "")
    verifier = is_verifier(wallet) if wallet else False

    import os

    rows = [
        {
            "evidence": item,
            "state": {"status": _DB_TO_CHAIN_STATUS.get(item.escrow.state, 0)},
        }
        for item in evidence
    ]

    return render(
        request,
        "oracle/index.html",
        {
            "rows": rows,
            "wallet_attached": bool(wallet),
            "is_verifier": verifier,
            "vault_address": os.getenv("SWEEFT_VAULT_ADDRESS", ""),
        },
    )


@require_GET
def attest_request(request):
    """Build the exact PQ attestation message for the connected verifier.

    The verifier signs it with its registered ML-DSA-87 key in QoreX
    (signArbitrary) and posts the signature back to `attest_submit`, which
    teams it with the relayed on-chain submission. The server never signs.
    """
    import os

    wallet = (request.session.get("wallet_account") or {}).get("evm", "")
    if not wallet:
        return JsonResponse({"error": "connect your wallet first"}, status=401)
    if not is_verifier(wallet):
        return JsonResponse({"error": "this wallet is not an authorized verifier"}, status=403)

    try:
        escrow_id = int(request.GET.get("escrow_id", ""))
        evidence_id = int(request.GET.get("evidence_id", ""))
    except (TypeError, ValueError):
        return JsonResponse({"error": "escrow_id and evidence_id are required"}, status=400)

    evidence = (
        FulfilmentEvidence.objects.filter(pk=evidence_id, escrow__on_chain_id=escrow_id)
        .select_related("escrow")
        .first()
    )
    if not evidence:
        return JsonResponse({"error": "evidence not found for this escrow"}, status=404)

    from apps.blockchain.services.reads import _vault_contract
    from integrations.qorechain.client import get_evm_client, get_network
    from integrations.qorechain.messages import verifier_attestation_message

    issued_at = int(time.time())
    expires_at = issued_at + MAX_ATTEST_AGE_SECONDS
    try:
        w3 = get_evm_client()
        vault = _vault_contract(w3)
        checksum = w3.to_checksum_address(wallet)
        from integrations.qorechain.contracts import artifact_path
        from integrations.qorechain.contracts_base import load_abi, make_contract

        registry = make_contract(w3, os.getenv("SWEEFT_ORACLE_REGISTRY_ADDRESS", ""), load_abi(artifact_path("SweeftOracleRegistry")))
        key_version = int(registry.functions.keyVersion(checksum).call())
        nonce = int(vault.functions.verifierNonce(checksum, escrow_id).call())
    except Exception:
        logger.exception("could not read verifier attestation params")
        return JsonResponse({"error": "chain read failed — try again"}, status=502)

    if key_version == 0:
        return JsonResponse(
            {"error": "this verifier predates PQ key pinning — a DAO key-version rotation is required first"},
            status=409,
        )

    message = verifier_attestation_message(
        chain_id=get_network().chain_id,
        vault=os.getenv("SWEEFT_VAULT_ADDRESS", ""),
        registry=os.getenv("SWEEFT_ORACLE_REGISTRY_ADDRESS", ""),
        verifier=wallet,
        key_version=key_version,
        escrow_id=escrow_id,
        evidence_hash=evidence.content_hash,
        issued_at=issued_at,
        expires_at=expires_at,
        nonce=nonce,
    )
    return JsonResponse(
        {
            "message": message,
            "escrow_id": escrow_id,
            "evidence_hash": evidence.content_hash,
            "issued_at": issued_at,
            "expires_at": expires_at,
            "nonce": nonce,
            "key_version": key_version,
            "verifier": checksum,
        }
    )


@require_POST
def attest_submit(request):
    """Relay a verifier's PQ-signed attestation (submitter can be anyone)."""
    import base64

    try:
        payload = json.loads(request.body or b"{}")
    except json.JSONDecodeError:
        return JsonResponse({"error": "invalid JSON body"}, status=400)

    try:
        escrow_id = int(payload.get("escrow_id", ""))
        evidence_hash = bytes.fromhex(str(payload.get("evidence_hash", "")).replace("0x", ""))
        issued_at = int(payload.get("issued_at", 0))
        expires_at = int(payload.get("expires_at", 0))
        signature = bytes.fromhex(str(payload.get("signature_pq_hex", "")).replace("0x", ""))
        verifier = str(payload.get("verifier", ""))
    except (TypeError, ValueError):
        return JsonResponse({"error": "malformed submission"}, status=400)

    wallet = (request.session.get("wallet_account") or {}).get("evm", "")
    # The signature authenticates the verifier; the session wallet merely
    # submits it (relayer submission is permissionless by design).
    if not verifier:
        return JsonResponse({"error": "verifier is required"}, status=400)

    from apps.blockchain.services.relayer import RelayerError, submit_verifier_attestation

    try:
        result = submit_verifier_attestation(escrow_id, verifier, evidence_hash, issued_at, expires_at, signature)
    except RelayerError as exc:
        return JsonResponse({"error": str(exc)[:300]}, status=502)
    except Exception as exc:
        logger.exception("verifier attestation relay failed")
        return JsonResponse({"error": str(exc)[:300]}, status=502)

    evidence = FulfilmentEvidence.objects.filter(escrow__on_chain_id=escrow_id, content_hash=evidence_hash.hex()).first()
    if evidence is None:
        evidence = FulfilmentEvidence.objects.filter(pk=payload.get("evidence_id")).first()
    if evidence is not None:
        evidence.attestation_tx = result["tx_hash"]
        evidence.verification_status = "verified"
        evidence.save(update_fields=["attestation_tx", "verification_status"])

    return JsonResponse({"ok": True, **result})
