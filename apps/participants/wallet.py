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

#: Challenges are single-use and short-lived.
CHALLENGE_TTL_SECONDS = 300


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
    issued = int(time.time())
    expires = issued + CHALLENGE_TTL_SECONDS
    domain = request.get_host()
    message = (
        f"Sweeft login\n"
        f"domain: {domain}\n"
        f"address: {address}\n"
        f"chain-id: {network.chain_id}\n"
        f"nonce: {nonce}\n"
        f"issued: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(issued))}\n"
        f"expires: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(expires))}"
    )
    request.session["wallet_challenge"] = {
        "message": message,
        "address": address.lower(),
        "issued_at": issued,
        "domain": domain,
    }
    return JsonResponse({"message": message, "nonce": nonce, "chain_id": network.chain_id, "expires_in": CHALLENGE_TTL_SECONDS})


def _verify_qorex(address: str, message: str, signature_pq_b64: str, message_signature_json: str | None = None) -> tuple[bool, str]:
    """Verify a QoreX message signature against the registered ML-DSA-87 key.

    Preferred path uses the official QoreSign library — verify_message over the
    full hybrid signature (classical + PQ). Fallback keeps an ML-DSA-only check
    for clients that only send the PQ part. This function is total: every
    malformed input shape returns (False, reason), never raises — a wallet
    login must never 500.
    """
    try:
        import qorsdk
        from qorsdk.address import bech32_to_hex, hex_to_bech32
    except Exception:
        return False, "server is missing the QoreChain SDK"

    # The REST key lookup only accepts the bech32 (qor1...) form — mobile
    # wallets sometimes hand us the hex form, which 400s. Normalise first.
    if address.lower().startswith("0x"):
        try:
            address = hex_to_bech32(address)
        except Exception:
            return False, "invalid EVM address"

    network = get_network()
    try:
        status = qorsdk.fetch_pqc_status(network.rest_url, address)
    except requests.RequestException:
        return False, "could not read the account's key from the chain — try again"
    except Exception as exc:
        logger.exception("pqc status read failed")
        return False, f"could not read the account's key from the chain ({str(exc)[:80]})"

    if not status.get("registered"):
        return False, "this account has no ML-DSA-87 key registered — open QoreX and register one first"

    public_key_b64 = status.get("pubkey") or (status.get("account") or {}).get("public_key")
    if not public_key_b64:
        return False, "the registered key could not be read"
    try:
        public_key = base64.b64decode(public_key_b64, validate=True)
    except Exception:
        try:
            public_key = base64.b64decode(public_key_b64)
        except Exception:
            return False, "malformed key encoding"
    if not len(public_key):
        return False, "malformed key encoding"

    if message_signature_json:
        try:
            from qoresign import message_signature_from_json, verify_message

            sig_obj = message_signature_from_json(message_signature_json)
            verify_message(network.chain_id, address.lower(), message.encode(), sig_obj, public_key, True)
        except Exception as exc:
            return False, f"QoreSign verification failed: {str(exc)[:160]}"
        try:
            bech32_to_hex(address)
        except Exception:
            return False, "invalid qor1 address"
        return True, ""

    payload = f"qorechain-msg-v1|{network.chain_id}|{message}".encode()
    try:
        # Mobile wallets sometimes send unpadded base64; restore padding.
        cleaned = (signature_pq_b64 or "").strip()
        cleaned += "=" * (-len(cleaned) % 4)
        signature = base64.b64decode(cleaned, validate=True)
    except Exception:
        return False, "malformed signature encoding"
    try:
        verified = qorsdk.pqc_verify(public_key, payload, signature)
    except Exception:
        verified = False
    if not verified:
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

    # Single-use + expiry: a challenge cannot be replayed or used late.
    issued_at = stored.get("issued_at")
    if not issued_at or (time.time() - float(issued_at)) > CHALLENGE_TTL_SECONDS:
        request.session.pop("wallet_challenge", None)
        return JsonResponse({"error": "challenge expired — press connect again"}, status=400)

    if method == "qorex":
        full_sig = payload.get("message_signature") or payload.get("signature_json")
        if full_sig is not None and not isinstance(full_sig, str):
            full_sig = json.dumps(full_sig)
        ok, reason = _verify_qorex(address, message, payload.get("signature_pq_b64", ""), full_sig)
    elif method == "evm":
        ok, reason = _verify_evm(address, message, payload.get("signature", ""))
    else:
        ok, reason = False, "unknown method"

    if not ok:
        # Do not leave a usable challenge behind on a failed attempt.
        request.session.pop("wallet_challenge", None)
        return JsonResponse({"error": reason}, status=401)

    # Normalise both address forms for display and future actions. Mobile
    # wallets sometimes send the "other" form (qor1 via EVM path or 0x via
    # QoreX); convert robustly instead of crashing (HTTP 500).
    from qorsdk.address import bech32_to_hex, hex_to_bech32

    try:
        if address.lower().startswith("qor1"):
            evm = "0x" + bech32_to_hex(address).lower().replace("0x", "")
            qor = address
        elif address.lower().startswith("0x"):
            evm = address
            qor = hex_to_bech32(address)
        else:
            return JsonResponse({"error": "unrecognized address format (want 0x… or qor1…)"}, status=400)
    except Exception:
        return JsonResponse({"error": "could not convert the address form — try again"}, status=400)

    # Rotate the session key on login to prevent fixation.
    request.session.cycle_key()
    request.session[SESSION_KEY] = {"evm": evm, "qor": qor, "method": method}
    request.session.pop("wallet_challenge", None)
    return JsonResponse({"ok": True, "evm": evm, "qor": qor, "method": method})


@require_POST
def logout(request):
    request.session.pop(SESSION_KEY, None)
    return JsonResponse({"ok": True})
