"""Public transaction verification — real on-chain checks, no mocks.

Given any Diana transaction hash, decode what it did and verify Sweeft's
post-quantum gates against live chain state:

- buyer ML-DSA-87 authorization (release/refund signature re-verified with
  `qorsdk.pqc_verify` under the buyer's chain-registered key; nonce
  reconstructed around the current one post-settlement)
- carrier signature validity (v2 domain message rebuilt + verified)
- verifier signature + registration status (keyVersion pin, isVerifier)
- escrow settlement state and credit recipients (fee split from events)
"""

from __future__ import annotations

import logging

from eth_abi import abi

from integrations.qorechain.client import get_network

logger = logging.getLogger(__name__)

_ATTEST_CARRIER = ["uint256", "string", "string", "bytes32", "uint64", "uint64", "bytes"]
_ATTEST_VERIFIER = ["uint256", "address", "bytes32", "uint64", "uint64", "bytes"]
_RELEASE = ["uint256", "bytes"]
_RESOLVE = ["uint256", "bool"]


def _w3():
    from web3 import Web3

    network = get_network()
    return Web3(Web3.HTTPProvider(network.evm_rpc_url, request_kwargs={"timeout": 15}))


def _vault(w3):
    import os

    from integrations.qorechain.contracts import artifact_path
    from integrations.qorechain.contracts_base import load_abi, make_contract

    address = os.getenv("SWEEFT_VAULT_ADDRESS", "")
    if not address:
        return None
    return make_contract(w3, address, load_abi(artifact_path("SweeftVault")))


def _registry(w3):
    import os

    from integrations.qorechain.contracts import artifact_path
    from integrations.qorechain.contracts_base import load_abi, make_contract

    address = os.getenv("SWEEFT_ORACLE_REGISTRY_ADDRESS", "")
    if not address:
        return None
    return make_contract(w3, address, load_abi(artifact_path("SweeftOracleRegistry")))


def _read_key(w3, address: str) -> tuple[bool, bool, int, bytes]:
    """(registered, proven, algorithmId, pubkey) via the PQC precompile."""
    try:
        target = w3.to_checksum_address(address)
    except Exception:
        from qorsdk.address import bech32_to_hex

        target = "0x" + bech32_to_hex(address).lower().replace("0x", "")
    selector = w3.keccak(text="pqcKeyStatus(address)").hex()[:8]
    padded = target.lower().replace("0x", "").rjust(64, "0")
    data = w3.eth.call(
        {
            "to": "0x0000000000000000000000000000000000000a02",
            "data": "0x" + selector + padded,
        }
    )
    registered, algo, pubkey, proven = abi.decode(["bool", "uint8", "bytes", "bool"], data)
    return bool(registered), bool(proven), int(algo), bytes(pubkey)


def _pq_verify(pubkey: bytes, signature: bytes, message: bytes) -> bool:
    from qorsdk import pqc_verify

    try:
        return bool(pqc_verify(pubkey, message, signature))
    except Exception:
        return False


def _selector_of(w3, signature_text: str) -> str:
    return (w3.keccak(text=signature_text)[:4]).hex().lower()


def _zero_hex(b32: bytes) -> str:
    return "0x" + b32.hex().rjust(64, "0")[2:]


def verify_transaction(tx_hash: str) -> dict:
    w3 = _w3()
    try:
        tx = w3.eth.get_transaction(tx_hash)
        receipt = w3.eth.get_transaction_receipt(tx_hash)
    except Exception:
        return {"error": "transaction not found on Diana EVM RPC", "tx_hash": tx_hash}

    vault = _vault(w3)
    data = tx.get("input", "0x") or "0x"
    selector = data[2:10].lower() if len(data) >= 10 else ""
    if vault is None or w3.to_checksum_address(tx["to"]) != vault.address:
        return {
            "error": "not a SweeftVault transaction",
            "tx_hash": tx_hash,
            "to": tx.get("to"),
        }

    result: dict = {
        "tx_hash": tx_hash,
        "from": tx.get("from"),
        "to": tx.get("to"),
        "block": receipt["blockNumber"],
        "status": int(receipt["status"]),
        "gas_used": int(receipt["gasUsed"]),
        "kind": "unknown Vault call",
        "checks": {},
        "events": _decode_events(vault, receipt),
        "settlement": None,
    }

    kind, args = _decode_call(w3, vault, data, selector)
    result["kind"] = kind
    if args is None:
        return result
    escrow_id = int(args[0]) if kind != "create_escrow" else None
    result["escrow_id"] = escrow_id

    try:
        state = vault.functions.getEscrow(escrow_id).call()
        result["settlement"] = {
            "escrow_status": int(state[5]),
            "buyer": state[0],
            "seller": state[1],
        }
        if kind in ("release", "refund"):
            result["checks"].update(_verify_buyer_authorization(w3, vault, args, kind == "refund"))
            buyer = state[0]
            seller = state[1]
            result["settlement"]["recipients"] = {
                "seller": seller,
                "seller_credit_wei": _credit(w3, vault, seller),
                "buyer_credit_wei": _credit(w3, vault, buyer),
            }
        elif kind == "attest_carrier":
            result["checks"].update(_verify_carrier_authorization(w3, vault, args))
        elif kind == "attest_verifier":
            result["checks"].update(_verify_verifier_authorization(w3, vault, args))
    except Exception as exc:
        logger.exception("verification pipeline failed")
        result["error"] = f"{type(exc).__name__}: {str(exc)[:160]}"

    return result


def _decode_call(w3, vault, data, selector):
    """Decode the vault call; returns (kind, decoded args or None)."""
    try:
        raw = bytes.fromhex(data[10:])
    except Exception:
        return "undecodable", None
    candidates = [
        ("release", _RELEASE, _selector_of(w3, "release(uint256,bytes)")),
        ("refund", _RELEASE, _selector_of(w3, "refundAfterDeadline(uint256,bytes)")),
        ("attest_carrier", _ATTEST_CARRIER, _selector_of(w3, "attestCarrierEvidence(uint256,string,string,bytes32,uint64,uint64,bytes)")),
        ("attest_verifier", _ATTEST_VERIFIER, _selector_of(w3, "attestEvidence(uint256,address,bytes32,uint64,uint64,bytes)")),
        ("resolve_dispute", _RESOLVE, _selector_of(w3, "resolveDispute(uint256,bool)")),
    ]
    for name, types, sig in candidates:
        if sig == selector:
            try:
                return name, abi.decode(raw, types)
            except Exception:
                return name, None
    return "other Vault call", None


def _credit(w3, vault, who: str) -> int:
    try:
        return int(vault.functions.credits(w3.to_checksum_address(who)).call())
    except Exception:
        return -1


def _verify_buyer_authorization(w3, vault, args, is_refund: bool) -> dict:
    from integrations.qorechain.messages import release_message, refund_message

    escrow_id, signature = args[0], bytes(args[1])
    state = vault.functions.getEscrow(escrow_id).call()
    buyer, seller, amount = state[0], state[1], int(state[2])
    recipient = buyer if is_refund else seller
    nonce_now = int(vault.functions.escrowNonce(escrow_id).call())
    registered, proven, _algo, pubkey = _read_key(w3, buyer)

    authorized = False
    used_nonce = None
    for attempt in (nonce_now - 1, nonce_now, nonce_now + 1):
        if attempt < 0:
            continue
        message = (
            refund_message(vault.address, escrow_id, buyer, recipient, amount, attempt)
            if is_refund
            else release_message(vault.address, escrow_id, buyer, recipient, amount, attempt)
        )
        payload = f"qorechain-msg-v1|qorechain-diana|{message}".encode()
        if _pq_verify(pubkey, signature, payload):
            authorized = True
            used_nonce = attempt
            break

    return {
        "buyer_ml_dsa_registered": bool(registered and proven),
        "buyer_ml_dsa_signature": authorized,
        "signature_nonce": used_nonce,
        "signature_present": len(signature) >= 4000,
    }


def _verify_carrier_authorization(w3, vault, args) -> dict:
    escrow_id, tracking, status, evidence_hash, issued_at, expires_at, signature = args
    signature = bytes(signature)
    evidence_hash = bytes(evidence_hash)
    state = vault.functions.getEscrow(escrow_id).call()
    # Escrow struct: 11=logisticsPartner, 19=carrierStatus, 22=carrierDelivered
    partner = state[11] if len(state) > 11 else None
    is_carrier = False
    try:
        is_carrier = bool(vault.functions.isCarrier(w3.to_checksum_address(partner)).call()) if partner else False
    except Exception:
        pass
    registered, proven, _algo, pubkey = _read_key(w3, partner or "0x0000000000000000000000000000000000000000")
    try:
        nonce_now = int(vault.functions.carrierNonce(w3.to_checksum_address(partner), escrow_id).call()) if partner else 0
    except Exception:
        nonce_now = 0

    authorized = False
    used_nonce = None
    if partner:
        for attempt in (nonce_now - 1, nonce_now, nonce_now + 1):
            if attempt < 0:
                continue
            try:
                message = vault.functions.buildCarrierMessage(
                    w3.to_checksum_address(partner),
                    escrow_id,
                    tracking,
                    status,
                    evidence_hash,
                    issued_at,
                    expires_at,
                    attempt,
                ).call()
            except Exception:
                continue
            if _pq_verify(pubkey, signature, message):
                authorized = True
                used_nonce = attempt
                break

    checks = {
        "carrier_registered_proven": bool(registered and proven),
        "carrier_signature": authorized,
        "carrier_is_registered_carrier": is_carrier,
        "carrier_nonce": used_nonce,
        "carrier_status_on_chain": str(state[19]) if len(state) > 19 else None,
        "carrier_delivered_on_chain": bool(state[22]) if len(state) > 22 else False,
    }
    return checks


def _verify_verifier_authorization(w3, vault, args) -> dict:
    escrow_id, verifier, evidence_hash, issued_at, expires_at, signature = args
    signature = bytes(signature)
    evidence_hash = bytes(evidence_hash)
    registry = _registry(w3)
    registered, proven, algo, pubkey = _read_key(w3, verifier)
    try:
        nonce_now = int(vault.functions.verifierNonce(w3.to_checksum_address(verifier), escrow_id).call())
    except Exception:
        nonce_now = 0

    # Pinned key version from the registry is authoritative (not the
    # precompile algo id, though they coincide at 1=ML-DSA-87).
    pinned_version = algo
    verifier_active = None
    if registry is not None:
        try:
            verifier_active = bool(registry.functions.isVerifier(w3.to_checksum_address(verifier)).call())
            pinned_version = int(registry.functions.keyVersion(w3.to_checksum_address(verifier)).call())
        except Exception:
            pass

    authorized = False
    used_nonce = None
    for attempt in (nonce_now - 1, nonce_now, nonce_now + 1):
        if attempt < 0:
            continue
        try:
            message = vault.functions.buildVerifierMessage(
                w3.to_checksum_address(verifier),
                pinned_version,
                escrow_id,
                evidence_hash,
                issued_at,
                expires_at,
                attempt,
            ).call()
        except Exception:
            continue
        if _pq_verify(pubkey, signature, message):
            authorized = True
            used_nonce = attempt
            break

    checks = {
        "verifier_registered": bool(registered and proven),
        "verifier_signature": authorized,
        "verifier_active": verifier_active,
        "verifier_key_version_pinned": pinned_version,
        "verifier_nonce": used_nonce,
    }
    return checks


def _decode_events(vault, receipt) -> list:
    events = []
    topics = receipt.get("logs", []) or []
    for name in ("FundsReleased", "FeeCollected", "DisputeResolved", "CarrierAttested", "EvidenceAttested"):
        try:
            kind = getattr(vault.events, name, None)
            if kind is None:
                continue
            for log in kind().process_receipt(receipt, errors="silent"):
                args = dict(log["args"])
                entry = {"type": name}
                for key in ("escrowId", "seller", "buyer", "amount", "nonce", "treasuryShare", "disputeShare"):
                    if key in args:
                        entry[key] = str(args[key])
                events.append(entry)
        except Exception:
            pass
    return events
