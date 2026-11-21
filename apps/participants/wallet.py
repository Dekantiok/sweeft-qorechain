"""Wallet login — connect by proving ownership of a QoreChain account.

Flow (the same shape as the reference app, adapted to QoreChain):
  1. GET  /api/wallet/challenge/?address=...  → server issues a one-time message
  2. The wallet signs it — QoreX with its ML-DSA-87 key (signArbitrary) or an
     EVM wallet with personal_sign
  3. POST /api/wallet/verify/                 → server verifies the signature
  4. The Django session remembers the account; the nav renders connected state.

QoreX signatures are verified against the account's **registered on-chain
ML-DSA-87 key**, so a login proves post-quantum key possession — not just a
classical signature.
"""

from __future__ import annotations

import base64
import json
import logging
import secrets
import time

import requests
from django.http import JsonResponse
from django.views.decorators.http import require_GET, require_POST

from integrations.qorechain.client import get_network

logger = logging.getLogger(__name__)

SESSION_KEY = "wallet_account"


def current_wallet(request) -> dict | None:
    """The connected wallet from the session, if any."""
    return request.session.get(SESSION_KEY)


@require_GET
def challenge(request):
    address = request.GET.get("address", "").strip()
    if not address:
        return JsonResponse({"error": "address is required"}, status=400)

    nonce = secrets.token_hex(16)
    network = get_network()
    message = (
        f"Sweeft login\n"
        f"address: {address}\n"
        f"nonce: {nonce}\n"
        f"issued: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}"
    )
    request.session["wallet_challenge"] = {"message": message, "address": address.lower()}
    return JsonResponse({"message": message, "nonce": nonce, "chain_id": network.chain_id})


def _verify_qorex(address: str, message: str, signature_pq_b64: str) -> tuple[bool, str]:
    """Verify an ML-DSA-87 signature against the account's registered key."""
    try:
        import qorsdk
        from qorsdk.address import bech32_to_hex
    except Exception:
        return False, "server is missing the QoreChain SDK"

    network = get_network()
    try:
        status = qorsdk.fetch_pqc_status(network.rest_url, address)
    except requests.RequestException:
        return False, "could not read the account's key from the chain — try again"

    if not status.get("registered"):
        return False, "this account has no ML-DSA-87 key registered — open QoreX and register one first"

    # fetch_pqc_status returns the normalised shape: { registered, pubkey, ... }
    public_key_b64 = status.get("pubkey") or (status.get("account") or {}).get("public_key")
    if not public_key_b64:
        return False, "the registered key could not be read"

    payload = f"qorechain-msg-v1|{network.chain_id}|{message}".encode()
    try:
        public_key = base64.b64decode(public_key_b64)
        signature = base64.b64decode(signature_pq_b64)
    except Exception:
        return False, "malformed signature encoding"

    if not qorsdk.pqc_verify(public_key, payload, signature):
        return False, "signature does not match the registered key"

    try:
        bech32_to_hex(address)  # validates the address shape
    except Exception:
        return False, "invalid qor1 address"
    return True, ""


def _verify_evm(address: str, message: str, signature_hex: str) -> tuple[bool, str]:
    """Verify an EIP-191 personal_sign signature and recover the signer."""
    try:
        from eth_account import Account
        from eth_account.messages import encode_defunct
    except Exception:
        return False, "server is missing eth-account"

    try:
        recovered = Account.recover_message(encode_defunct(text=message), signature=signature_hex)
    except Exception:
        return False, "malformed signature"

    if recovered.lower() != address.lower():
        return False, "signature does not match the address"
    return True, ""


@require_POST
def verify(request):
    try:
        payload = json.loads(request.body or b"{}")
    except json.JSONDecodeError:
        return JsonResponse({"error": "invalid JSON body"}, status=400)

    method = payload.get("method", "evm")
    address = (payload.get("address") or "").strip()
    message = payload.get("message") or ""
    stored = request.session.get("wallet_challenge") or {}

    if not address or not message:
        return JsonResponse({"error": "address and message are required"}, status=400)
    if message != stored.get("message") or address.lower() != stored.get("address"):
        return JsonResponse({"error": "challenge mismatch — press connect again"}, status=400)

    if method == "qorex":
        ok, reason = _verify_qorex(address, message, payload.get("signature_pq_b64", ""))
    elif method == "evm":
        ok, reason = _verify_evm(address, message, payload.get("signature", ""))
    else:
        ok, reason = False, "unknown method"

    if not ok:
        return JsonResponse({"error": reason}, status=401)

    # Normalise both address forms for display and future actions.
    from qorsdk.address import bech32_to_hex, hex_to_bech32

    if method == "qorex":
        evm = "0x" + bech32_to_hex(address).replace("0x", "")
        qor = address
    else:
        evm = address
        qor = hex_to_bech32(address)

    request.session[SESSION_KEY] = {"evm": evm, "qor": qor, "method": method}
    request.session.pop("wallet_challenge", None)
    return JsonResponse({"ok": True, "evm": evm, "qor": qor, "method": method})


@require_POST
def logout(request):
    request.session.pop(SESSION_KEY, None)
    return JsonResponse({"ok": True})
