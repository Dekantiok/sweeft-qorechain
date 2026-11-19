"""Escrow views — status display and the PQ-signed release flow.

Release works as a meta-transaction: the buyer signs the release message in
their wallet (QoreX signArbitrary — ML-DSA-87), posts the signature here, and
the relayer submits it on-chain. The contract verifies the signature with
`pqcVerify`; the server never holds user keys and cannot forge a release.
"""

from __future__ import annotations

import json
import logging

from django.http import JsonResponse
from django.shortcuts import get_object_or_404, render
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_POST

from apps.blockchain.services.relayer import RelayerError, escrow_state, submit_release
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

    return render(
        request,
        "escrow/detail.html",
        {
            "escrow": escrow,
            "live": live_state,
            "network": get_network(),
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
        }
    )


@csrf_exempt
@require_POST
def release_submit(request, escrow_id: int):
    """Accept the wallet-produced ML-DSA-87 signature and relay the release."""
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

    try:
        result = submit_release(escrow_id, signature)
    except RelayerError as exc:
        return JsonResponse({"error": str(exc)}, status=400)
    except Exception as exc:  # pragma: no cover
        logger.exception("release relay failed")
        return JsonResponse({"error": f"relay failed: {exc}"}, status=502)

    return JsonResponse({"ok": True, **result})
