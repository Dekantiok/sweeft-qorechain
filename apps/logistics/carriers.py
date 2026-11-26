"""Carrier adapters — Demo Carrier (simulated) + ML-DSA-87 payload signing.

A real carrier implements CarrierAdapter and signs canonical payloads with its
QoreChain account's ML-DSA-87 key. The vault verifies that signature on-chain
via pqcVerify, so no TEE is needed. DemoCarrier is labelled simulated
everywhere; it generates deterministic tracking data for the demo.
"""

from __future__ import annotations

import hashlib
import time
from datetime import datetime, timezone

from django.conf import settings

from .models import Shipment, ShipmentEvent

HAPPY_FLOW = ["CREATED", "ACCEPTED", "PICKED_UP", "IN_TRANSIT", "OUT_FOR_DELIVERY", "DELIVERED"]
FAILURE_STATUSES = {"DELIVERY_FAILED", "RETURNED", "LOST", "CANCELLED"}
TERMINAL_STATUSES = FAILURE_STATUSES | {"DELIVERED"}
ALL_STATUSES = {choice[0] for choice in Shipment.STATUS_CHOICES}


def _event_ts_ms(event: dict, issued_at: int) -> int:
    ts = (event or {}).get("ts")
    if ts is not None:
        try:
            return int(ts)
        except (TypeError, ValueError):
            pass
    raw = (event or {}).get("timestamp")
    if raw:
        try:
            parsed = datetime.fromisoformat(str(raw))
        except (TypeError, ValueError):
            parsed = None
        if parsed is not None:
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            try:
                return int(parsed.timestamp() * 1000)
            except (OverflowError, OSError, ValueError):
                pass
    return int(issued_at)


def _canonical_ts(value) -> str:
    if value is None:
        return ""
    try:
        return str(int(value))
    except (TypeError, ValueError):
        return ""


def canonical_carrier_message(payload: dict) -> str:
    """Canonical signing message — MUST match the vault byte-for-byte.

    sweeft-carrier-v1|provider_id|tracking_number|escrow_id|status|issued_at|<events>
    Each event renders as <status>@<ts_ms>.
    """
    events = ",".join(
        f"{str((e or {}).get('status', ''))}@{_canonical_ts((e or {}).get('ts'))}"
        for e in (payload.get("events") or [])
    )
    return (
        f"sweeft-carrier-v1|{payload.get('provider_id', '')}|{payload.get('tracking_number', '')}"
        f"|{payload.get('escrow_id', '')}|{payload.get('status', '')}|{payload.get('issued_at', 0)}|{events}"
    )


def canonical_carrier_attestation(
    provider_id: str,
    tracking_number: str,
    escrow_id: int,
    status: str,
    issued_at: int,
    nonce: int,
) -> str:
    """v5 on-chain attestation message — MUST match SweeftVault._carrierMessage.

    The vault rebuilds this from (carrier, escrowId, tracking, status,
    issuedAt, nonce) and verifies the carrier's ML-DSA-87 signature over it,
    binding the attestation to one escrow, carrier, status and nonce.
    """
    return (
        f"sweeft-carrier-v1|provider={provider_id}|tracking={tracking_number}"
        f"|escrow={escrow_id}|status={status}|issued={issued_at}|nonce={nonce}"
    )


def hash_attestation(message: str) -> str:
    """keccak256 hex of an attestation message (matches the vault's hash)."""
    from eth_utils import keccak

    return keccak(message.encode()).hex()


def sign_carrier_attestation(
    escrow_id: int,
    tracking_number: str,
    status: str,
    nonce: int,
    issued_at: int | None = None,
) -> dict:
    """Sign the v5 on-chain attestation message with the Demo Carrier key.

    `issued_at` is in **seconds** (the vault bounds it to the last 7 days).
    """
    if issued_at is None:
        issued_at = int(time.time())
    keypair, _, _ = demo_carrier_keypair()
    message = canonical_carrier_attestation(
        DemoCarrier.provider_id, tracking_number, escrow_id, status, issued_at, nonce
    )
    from qorsdk import pqc_sign

    signature = pqc_sign(keypair.secret_key, message.encode()).hex()
    return {
        "message": message,
        "signature": signature,
        "issued_at": issued_at,
        "nonce": nonce,
        "provider_id": DemoCarrier.provider_id,
        "simulated": True,
    }


def demo_carrier_keypair():
    """Demo carrier's ML-DSA-87 keypair, derived from the testnet mnemonic (index 6)."""
    import os

    from qorsdk import derive_unified_account

    from integrations.qorechain.client import get_network

    if get_network().network != "testnet":
        raise ValueError("Demo Carrier is testnet-only")
    # Prefer a dedicated mnemonic; falling back to the deployer mnemonic
    # (owner keys) works for the throwaway demo but should be a conscious,
    # visible choice — log it so a misconfigured deploy is obvious.
    import logging
    import warnings

    mnemonic = os.getenv("DEMO_CARRIER_MNEMONIC", "")
    if not mnemonic:
        mnemonic = os.getenv("SWEEFT_DEPLOYER_MNEMONIC", "")
        if mnemonic:
            warnings.warn(
                "Demo Carrier is using SWEEFT_DEPLOYER_MNEMONIC (owner keys). "
                "Set DEMO_CARRIER_MNEMONIC to a dedicated testnet account.",
                stacklevel=2,
            )
            logging.getLogger(__name__).warning(
                "Demo Carrier key derived from deployer mnemonic — set DEMO_CARRIER_MNEMONIC"
            )
    if not mnemonic:
        raise ValueError("Demo Carrier key is not configured — set DEMO_CARRIER_MNEMONIC or SWEEFT_DEPLOYER_MNEMONIC")
    account = derive_unified_account(mnemonic.strip(), index=6)
    return account.pqc, account.cosmos, account.evm


def sign_carrier_payload(payload: dict) -> dict:
    """Attach the Demo Carrier ML-DSA-87 signature (key registered on-chain)."""
    keypair, _, _ = demo_carrier_keypair()
    issued_at = int(time.time() * 1000)
    payload["issued_at"] = issued_at
    events = payload.get("events")
    if isinstance(events, list):
        for e in events:
            if isinstance(e, dict):
                e["ts"] = _event_ts_ms(e, issued_at)
    from qorsdk import pqc_sign

    payload["signature"] = pqc_sign(keypair.secret_key, canonical_carrier_message(payload).encode()).hex()
    return payload


def verify_carrier_payload(payload: dict, pubkey_hex: str | None = None) -> bool:
    """Off-chain check of a carrier payload signature (the chain also verifies)."""
    from qorsdk import pqc_sign  # noqa: F401  (we need pqc_verify)
    from qorsdk import pqc_verify  # type: ignore

    _, cosmos, _ = demo_carrier_keypair()
    if pubkey_hex is None:
        from qorsdk import fetch_pqc_status

        status = fetch_pqc_status(getattr(settings, "QORECHAIN_REST_URL", "https://api-testnet.qore.host"), cosmos)
        pubkey_hex = status.get("pubkey", "")
    msg = canonical_carrier_message(payload).encode()
    sig = bytes.fromhex(payload.get("signature", ""))
    return pqc_verify(bytes.fromhex(pubkey_hex), msg, sig)


class CarrierAdapter:
    def quote(self, origin: str, destination: str, weight_kg: float) -> dict:  # pragma: no cover
        raise NotImplementedError

    def create_shipment(self, escrow_id: str, origin: str, destination: str) -> dict:  # pragma: no cover
        raise NotImplementedError

    def tracking(self, tracking_number: str) -> dict:  # pragma: no cover
        raise NotImplementedError


class DemoCarrier(CarrierAdapter):
    name = "Demo Carrier (simulated)"
    provider_id = "LOG-DEMO-001"

    def quote(self, origin: str, destination: str, weight_kg: float) -> dict:
        base_qor = 100_000  # uqor starter
        price = base_qor + int(weight_kg * 10_000)
        return {
            "carrier": "demo",
            "simulated": True,
            "origin": origin,
            "destination": destination,
            "weight_kg": weight_kg,
            "price_uqor": str(price),
            "note": "SIMULATED QUOTE — Demo Carrier, not a real carrier rate.",
        }

    def create_shipment(self, escrow_id: str, origin: str, destination: str) -> dict:
        digest = hashlib.sha256(f"{escrow_id}:{origin}:{destination}".encode()).hexdigest()[:8].upper()
        return {"tracking_number": f"DEMO-{digest}", "simulated": True, "status": "CREATED"}

    def tracking(self, tracking_number: str) -> dict:
        shipment = Shipment.objects.filter(tracking_number=tracking_number).first()
        if not shipment:
            return {"simulated": True, "error": "unknown tracking number"}
        events = list(shipment.events.values("status", "created_at", "note"))
        return {
            "simulated": True,
            "provider_id": self.provider_id,
            "carrier": "demo",
            "tracking_number": shipment.tracking_number,
            "escrow_id": str(shipment.escrow.on_chain_id) if shipment.escrow else "",
            "status": shipment.status,
            "events": [
                {"status": e["status"], "timestamp": e["created_at"].isoformat(), "note": e["note"]}
                for e in events
            ],
            "note": "SIMULATED TRACKING — Demo Carrier. Not a real carrier integration.",
        }

    def advance(self, shipment: Shipment, to_status: str | None = None, note: str = "") -> ShipmentEvent:
        current = shipment.status
        if to_status is None:
            try:
                idx = HAPPY_FLOW.index(current)
            except ValueError:
                idx = -1
            to_status = HAPPY_FLOW[idx + 1] if idx + 1 < len(HAPPY_FLOW) else current
        to_status = to_status.strip().upper()

        if to_status not in ALL_STATUSES:
            raise ValueError(f"unknown status {to_status!r} — one of {sorted(ALL_STATUSES)}")

        if to_status == current:
            existing = shipment.events.order_by("-created_at").first()
            if existing and existing.status == current:
                return existing

        if current in TERMINAL_STATUSES:
            raise ValueError(f"shipment is already {current} — no further transitions")

        if (
            to_status not in FAILURE_STATUSES
            and current in HAPPY_FLOW
            and HAPPY_FLOW.index(to_status) < HAPPY_FLOW.index(current)
        ):
            raise ValueError(f"cannot move backwards: {current} → {to_status}")

        shipment.status = to_status
        shipment.save(update_fields=["status", "updated_at"])
        return ShipmentEvent.objects.create(
            shipment=shipment,
            status=to_status,
            note=note or "Simulated scan by Demo Carrier",
            simulated=True,
            raw={"simulated": True, "source": "demo_carrier.advance", "previous": current},
        )


def get_carrier() -> DemoCarrier:
    return DemoCarrier()
