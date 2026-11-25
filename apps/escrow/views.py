"""Escrow views — status display and the PQ-signed release flow.

Release works as a meta-transaction: the buyer signs the release message in
their wallet (QoreX signArbitrary — ML-DSA-87), posts the signature here, and
the relayer submits it on-chain. The contract verifies the signature with
`pqcVerify`; the server never holds user keys and cannot forge a release.
"""

from __future__ import annotations

import hashlib
import json
import logging
from datetime import timedelta

from django.http import JsonResponse
from django.shortcuts import get_object_or_404, render
from django.views.decorators.http import require_GET, require_POST

from apps.blockchain.services.relayer import RelayerError, escrow_state, is_verifier, submit_release
from apps.oracle.models import FulfilmentEvidence
from config.ratelimit import is_rate_limited
from integrations.qorechain.client import get_network
from integrations.qorechain.messages import release_message

from .models import Escrow

logger = logging.getLogger(__name__)


def escrow_detail(request, escrow_id: int):
    escrow = get_object_or_404(
        Escrow.objects.select_related("order", "order__listing", "buyer", "seller"), on_chain_id=escrow_id
    )

    live_state = None
    try:
        live_state = escrow_state(escrow_id)
    except Exception:
        logger.exception("could not read on-chain escrow state")

    import os

    wallet = (request.session.get("wallet_account") or {}).get("evm", "").lower()
    evidence = FulfilmentEvidence.objects.filter(escrow=escrow).order_by("-submitted_at")

    from apps.logistics.models import Shipment, VerificationRequest

    shipment = Shipment.objects.filter(escrow=escrow).order_by("-created_at").first()
    verification = VerificationRequest.objects.filter(escrow=escrow).order_by("-created_at").first()

    amount_wei = live_state.get("amount_wei") if live_state else int(escrow.amount_uqor) * 10**12
    dispute_bond_wei = max(10**17, int(amount_wei) // 100)  # 1% with a 0.1 QOR floor

    return render(
        request,
        "escrow/detail.html",
        {
            "escrow": escrow,
            "live": live_state,
            "network": get_network(),
            "dispute_board_address": os.getenv("SWEEFT_DISPUTE_BOARD_ADDRESS", ""),
            "dispute_bond_wei": dispute_bond_wei,
            "appeal_bond_wei": dispute_bond_wei * 2,
            "vault_address": os.getenv("SWEEFT_VAULT_ADDRESS", ""),
            "evidence": evidence,
            "shipment": shipment,
            "verification": verification,
            "is_buyer": bool(wallet) and wallet == escrow.buyer.evm_address.lower(),
            "is_seller": bool(wallet) and wallet == escrow.seller.evm_address.lower(),
            "wallet_attached": bool(wallet),
        },
    )


@require_GET
def release_request(request, escrow_id: int):
    """Build the exact message the buyer must sign in their wallet."""
    escrow = get_object_or_404(Escrow, on_chain_id=escrow_id)
    network = get_network()

    try:
        state = escrow_state(escrow_id)
    except Exception as exc:
        return JsonResponse({"error": f"chain read failed: {exc}"}, status=502)

    if not state["release_eligible"]:
        return JsonResponse(
            {"error": "escrow is not release-eligible yet", "state": state}, status=409
        )

    import os

    from qorsdk.address import hex_to_bech32

    message = release_message(
        vault=os.environ["SWEEFT_VAULT_ADDRESS"],
        escrow_id=escrow_id,
        buyer=state["buyer"],
        recipient=state["seller"],
        amount_wei=state["amount_wei"],
        nonce=state["pqc_nonce"],
    )

    return JsonResponse(
        {
            "escrow_id": escrow_id,
            "message": message,
            "chain_id": network.chain_id,
            "evm_chain_id": network.evm_chain_id,
            "buyer_evm": state["buyer"],
            "buyer_qor": hex_to_bech32(state["buyer"]),
            "nonce": state["pqc_nonce"],
            "amount_wei": state["amount_wei"],
            "recipient": state["seller"],
            "preauth": True,  # same message the autopilot will submit exactly once
        }
    )


@require_POST
def release_submit(request, escrow_id: int):
    """Accept the wallet-produced ML-DSA-87 signature and relay the release."""
    internal = _internal_token_ok(request)
    if not internal and is_rate_limited("release-submit", request, 5):
        return JsonResponse({"error": "slow down"}, status=429)
    try:
        payload = json.loads(request.body or b"{}")
    except json.JSONDecodeError:
        return JsonResponse({"error": "invalid JSON body"}, status=400)

    signature_b64 = payload.get("signature_pq_b64")
    if not signature_b64:
        return JsonResponse({"error": "signature_pq_b64 is required"}, status=400)

    import base64

    try:
        signature = base64.b64decode(signature_b64)
    except Exception:
        return JsonResponse({"error": "signature is not valid base64"}, status=400)
    if not _valid_ml_dsa_signature(signature):
        return JsonResponse({"error": "signature is not a plausible ML-DSA-87 signature"}, status=400)

    try:
        result = submit_release(escrow_id, signature)
    except RelayerError as exc:
        return JsonResponse({"error": str(exc)}, status=400)
    except Exception as exc:  # pragma: no cover
        logger.exception("release relay failed")
        return JsonResponse({"error": f"relay failed: {exc}"}, status=502)

    return JsonResponse({"ok": True, **result})


# ---------------------------------------------------------------------------
# Autopilot — pre-authorized release
# ---------------------------------------------------------------------------

#: A stored pre-signed release is a bearer authorization; it expires on its own
#: and is cleared once used.
AUTOPILOT_TTL = timedelta(days=30)
#: ML-DSA-87 signatures are 4,627 bytes (base64 ~6,172 chars). Reject anything
#: wildly outside that range before spending relayer gas.
ML_DSA_87_SIG_LEN = 4627


def _valid_ml_dsa_signature(signature: bytes) -> bool:
    # Allow a small tolerance for encodings; reject obviously wrong blobs.
    return ML_DSA_87_SIG_LEN - 64 <= len(signature) <= ML_DSA_87_SIG_LEN + 64


def _session_wallet(request) -> str:
    return (request.session.get("wallet_account") or {}).get("evm", "").lower()


def _require_buyer(request, escrow):
    """Return an error response unless the session wallet is the escrow buyer."""
    wallet = _session_wallet(request)
    if not wallet:
        return JsonResponse({"error": "connect your wallet first"}, status=401)
    if escrow.buyer.evm_address.lower() != wallet:
        return JsonResponse({"error": "only the buyer can do this"}, status=403)
    return None


def _internal_token_ok(request) -> bool:
    import hmac
    import os

    expected = os.getenv("SWEEFT_INTERNAL_TOKEN", "")
    if not expected:
        return False
    provided = request.headers.get("X-Internal-Token", "")
    # Constant-time comparison (N-12).
    return hmac.compare_digest(provided, expected)


@require_POST
def autopilot_pre_authorize(request, escrow_id: int):
    """Buyer pre-signs the release (QoreX) — the AI may submit exactly this
    signature later when the escrow becomes release-eligible, inside the
    cap the buyer approved. Scope is frozen: escrow, recipient, amount, nonce.
    """
    escrow = get_object_or_404(Escrow, on_chain_id=escrow_id)
    denied = _require_buyer(request, escrow)
    if denied:
        return denied

    try:
        payload = json.loads(request.body or b"{}")
    except json.JSONDecodeError:
        return JsonResponse({"error": "invalid JSON body"}, status=400)

    signature_b64 = payload.get("signature_pq_b64")
    if not signature_b64:
        return JsonResponse({"error": "signature_pq_b64 is required"}, status=400)

    import base64
    from django.utils import timezone

    try:
        signature = base64.b64decode(signature_b64)
    except Exception:
        return JsonResponse({"error": "signature is not valid base64"}, status=400)
    if not _valid_ml_dsa_signature(signature):
        return JsonResponse({"error": "signature is not a plausible ML-DSA-87 signature"}, status=400)

    escrow.autopilot_enabled = True
    escrow.autopilot_release_signature_b64 = signature_b64
    escrow.autopilot_signer = escrow.buyer.evm_address
    escrow.autopilot_authorized_at = timezone.now()
    escrow.save(update_fields=[
        "autopilot_enabled", "autopilot_release_signature_b64",
        "autopilot_signer", "autopilot_authorized_at", "updated_at",
    ])
    return JsonResponse({"ok": True, "escrow_id": escrow_id, "expires_in_days": AUTOPILOT_TTL.days, "signed_scope": {
        "amount_wei": escrow.amount_uqor, "nonce": escrow.pqc_nonce,
        "note": "One-time — the carrier pays the exact recipient/amount this signature allows, nothing more.",
    }})


@require_POST
def autopilot_execute(request, escrow_id: int):
    """Submit the stored pre-signed release if the escrow is eligible.

    Internal/agent-facing: callers must present the worker token (X-Internal-Token)
    or be the buyer's own session. Verifies shape, expiry and chain eligibility
    before relaying. Idempotent: a completed escrow returns its tx.
    """
    import base64

    escrow = get_object_or_404(Escrow, on_chain_id=escrow_id)
    caller_is_buyer = _session_wallet(request) == escrow.buyer.evm_address.lower()
    if not (caller_is_buyer or _internal_token_ok(request)):
        return JsonResponse({"error": "not authorized to execute autopilot"}, status=403)

    if not escrow.autopilot_enabled or not escrow.autopilot_release_signature_b64:
        return JsonResponse({"error": "no pre-authorization stored for this escrow"}, status=409)

    from django.utils import timezone

    if escrow.autopilot_authorized_at and timezone.now() - escrow.autopilot_authorized_at > AUTOPILOT_TTL:
        escrow.autopilot_enabled = False
        escrow.autopilot_release_signature_b64 = ""
        escrow.save(update_fields=["autopilot_enabled", "autopilot_release_signature_b64", "updated_at"])
        return JsonResponse({"error": "pre-authorization expired — ask the buyer to sign again"}, status=409)

    try:
        state = escrow_state(escrow_id)
    except Exception as exc:
        return JsonResponse({"error": f"chain read failed: {exc}"}, status=502)

    if state["status"] == 2:
        return JsonResponse({"ok": True, "already": True, "tx_hash": escrow.release_tx or escrow.autopilot_execute_tx})
    if not state["release_eligible"]:
        return JsonResponse({"error": "not yet release-eligible (needs verifier/carrier attestation or the inspection window)", "state": state}, status=409)

    signature = base64.b64decode(escrow.autopilot_release_signature_b64)
    try:
        result = submit_release(escrow_id, signature)
    except RelayerError as exc:
        return JsonResponse({"error": str(exc)}, status=400)
    except Exception as exc:  # pragma: no cover
        logger.exception("autopilot execute failed")
        return JsonResponse({"error": f"relay failed: {exc}"}, status=502)

    escrow.autopilot_execute_tx = result["tx_hash"]
    # Single-use bearer authorization: clear it after execution.
    escrow.autopilot_enabled = False
    escrow.autopilot_release_signature_b64 = ""
    escrow.save(update_fields=["autopilot_execute_tx", "autopilot_enabled", "autopilot_release_signature_b64", "updated_at"])
    return JsonResponse({"ok": True, **result})


@require_POST
def autopilot_revoke(request, escrow_id: int):
    """Buyer revokes the stored pre-authorization (does not affect the chain)."""
    escrow = get_object_or_404(Escrow, on_chain_id=escrow_id)
    denied = _require_buyer(request, escrow)
    if denied:
        return denied
    escrow.autopilot_enabled = False
    escrow.autopilot_release_signature_b64 = ""
    escrow.save(update_fields=["autopilot_enabled", "autopilot_release_signature_b64", "updated_at"])
    return JsonResponse({"ok": True, "escrow_id": escrow_id})


@require_POST
def evidence_submit(request, escrow_id: int):
    """Seller/buyer submits fulfilment evidence — stored off-chain, hash-ready."""
    escrow = get_object_or_404(Escrow, on_chain_id=escrow_id)

    try:
        payload = json.loads(request.body or b"{}")
    except json.JSONDecodeError:
        return JsonResponse({"error": "invalid JSON body"}, status=400)

    wallet = _session_wallet(request)
    if not wallet:
        return JsonResponse({"error": "connect your wallet first"}, status=401)

    # Only a party to the escrow (buyer, seller or assigned carrier) may submit
    # evidence — otherwise the verifier queue can be spammed by anyone.
    parties = {escrow.buyer.evm_address.lower(), escrow.seller.evm_address.lower()}
    if (escrow.logistics_partner_address or "").lower():
        parties.add(escrow.logistics_partner_address.lower())
    if wallet not in parties:
        return JsonResponse({"error": "you are not a party to this escrow"}, status=403)

    # Cap evidence volume per escrow so a single party cannot flood reviewers.
    MAX_EVIDENCE_PER_ESCROW = 20
    if FulfilmentEvidence.objects.filter(escrow=escrow).count() >= MAX_EVIDENCE_PER_ESCROW:
        return JsonResponse({"error": "evidence limit reached for this escrow"}, status=429)

    evidence_type = payload.get("evidence_type", FulfilmentEvidence.EvidenceType.OTHER)
    valid_types = {choice.value for choice in FulfilmentEvidence.EvidenceType}
    if evidence_type not in valid_types:
        return JsonResponse({"error": "unknown evidence type"}, status=400)

    reference = str(payload.get("evidence_reference", "")).strip()[:500]
    description = str(payload.get("description", "")).strip()[:4000]
    if not reference and not description:
        return JsonResponse({"error": "provide a reference or a description"}, status=400)

    from apps.blockchain.services.indexer import _participant_for

    record = {
        "escrow_id": escrow_id,
        "evidence_type": evidence_type,
        "evidence_reference": reference,
        "description": description,
        "submitted_by": wallet,
    }
    content_hash = "0x" + hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()

    evidence = FulfilmentEvidence.objects.create(
        escrow=escrow,
        submitted_by=_participant_for(wallet),
        evidence_type=evidence_type,
        evidence_reference=reference,
        description=description,
        content_hash=content_hash,
    )
    return JsonResponse(
        {"ok": True, "id": evidence.pk, "content_hash": content_hash, "escrow_id": escrow_id}
    )
