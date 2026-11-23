"""Logistics views — directory, partner portal, shipment tracking, and the
Partner API (API-key auth) that automated carrier systems call.
"""

from __future__ import annotations

import hashlib
import json

from django.contrib import messages
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_POST

from apps.blockchain.services.relayer import escrow_state
from apps.escrow.models import Escrow

from . import carriers
from .models import LogisticsPartner, PartnerApiCredential, Shipment, VerificationRequest


def _wallet(request):
    return (request.session.get("wallet_account") or {}).get("evm", "")


def _read_json(request):
    try:
        return json.loads(request.body or b"{}")
    except json.JSONDecodeError:
        return None


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------


def directory(request):
    partners = LogisticsPartner.objects.filter(status="ACTIVE")
    return render(request, "logistics/directory.html", {"partners": partners})


def partner_register(request):
    wallet = _wallet(request)
    if not wallet:
        return redirect("/?connect=1")
    if request.method == "POST":
        company = request.POST.get("company_name", "").strip()
        if not company:
            messages.error(request, "Company name is required.")
            return redirect("logistics:partner_register")
        partner = LogisticsPartner.objects.create(
            company_name=company,
            registration_number=request.POST.get("registration_number", "").strip(),
            email=request.POST.get("email", "").strip(),
            website=request.POST.get("website", "").strip(),
            business_address=request.POST.get("business_address", "").strip(),
            contact_person=request.POST.get("contact_person", "").strip(),
            phone=request.POST.get("phone", "").strip(),
            operating_locations=request.POST.get("operating_locations", "").strip(),
            services=request.POST.get("services", "").strip(),
            tracking_api_endpoint=request.POST.get("tracking_api_endpoint", "").strip(),
            settlement_wallet=(request.POST.get("settlement_wallet", "") or wallet).strip(),
            provider_id=(request.POST.get("provider_id", "") or f"LOG-{abs(hash(company)) % 100000}"),
            pricing_note=request.POST.get("pricing_note", "").strip(),
            owner_wallet=wallet,
            status="PENDING",
        )
        messages.success(request, f"Application for {partner.company_name} submitted — an admin will review it.")
        return redirect("logistics:partner_portal")
    return render(request, "logistics/partner_register.html")


def partner_portal(request):
    wallet = _wallet(request)
    if not wallet:
        return redirect("/?connect=1")
    partners = LogisticsPartner.objects.filter(owner_wallet=wallet)
    if not partners.exists():
        return render(request, "logistics/partner_gate.html")
    shipments = Shipment.objects.filter(provider__in=partners).select_related("provider", "escrow")
    settlements = Escrow.objects.filter(state="completed", shipments__provider__in=partners).distinct()
    credentials = PartnerApiCredential.objects.filter(partner__in=partners, active=True)
    return render(
        request,
        "logistics/partner_portal.html",
        {"partners": partners, "shipments": shipments, "settlements": settlements, "credentials": credentials},
    )


@require_POST
def api_issue_partner_credential(request, partner_id: int):
    partner = get_object_or_404(LogisticsPartner, pk=partner_id)
    if partner.owner_wallet.lower() != _wallet(request).lower():
        return JsonResponse({"ok": False, "error": "not your partner profile"}, status=403)
    if partner.status != "ACTIVE":
        return JsonResponse({"ok": False, "error": "partner must be ACTIVE before credentials are issued"}, status=400)
    raw_key, credential = PartnerApiCredential.generate(partner)
    return JsonResponse({"ok": True, "raw_key": raw_key, "prefix": credential.prefix})


# ---------------------------------------------------------------------------
# JSON API (wallet session)
# ---------------------------------------------------------------------------


@require_POST
def api_create_shipment(request):
    body = _read_json(request)
    if body is None:
        return JsonResponse({"ok": False, "error": "invalid JSON body"}, status=400)
    escrow_id = str(body.get("escrow_id", "")).strip()
    escrow = Escrow.objects.filter(on_chain_id=int(escrow_id) if escrow_id.isdigit() else None).first()
    if not escrow:
        return JsonResponse({"ok": False, "error": "escrow not found"}, status=404)
    if escrow.state not in ("created", "funded", "fulfilled"):
        return JsonResponse({"ok": False, "error": f"escrow is {escrow.state}"}, status=400)

    wallet = _wallet(request).lower()
    if wallet not in (escrow.seller.evm_address.lower(), escrow.buyer.evm_address.lower()):
        return JsonResponse({"ok": False, "error": "only buyer or seller can register a shipment"}, status=403)

    valid_scenarios = {c[0] for c in Shipment.SIMULATION_SCENARIOS}
    scenario = str(body.get("scenario") or "delivered").strip().lower()
    if scenario not in valid_scenarios:
        return JsonResponse({"ok": False, "error": f"scenario must be one of {sorted(valid_scenarios)}"}, status=400)

    carrier = carriers.get_carrier()
    provided = str(body.get("tracking_number") or "").strip()
    created = carrier.create_shipment(str(escrow.on_chain_id), body.get("origin", "Lagos"), body.get("destination", "Abuja"))
    tracking = provided or created["tracking_number"]

    provider = LogisticsPartner.objects.filter(status="ACTIVE").first()
    shipment, was_created = Shipment.objects.get_or_create(
        tracking_number=tracking,
        defaults={
            "escrow": escrow,
            "provider": provider,
            "carrier": "demo",
            "status": "CREATED",
            "simulated": True,
            "simulation_scenario": scenario,
            "registered_by": wallet,
        },
    )
    if was_created:
        from .models import ShipmentEvent

        ShipmentEvent.objects.create(shipment=shipment, status="CREATED", note="Tracking created (simulated)", simulated=True)
    return JsonResponse(
        {
            "ok": True,
            "shipment_id": shipment.id,
            "tracking_number": shipment.tracking_number,
            "status": shipment.status,
            "scenario": shipment.simulation_scenario,
            "simulated": True,
        }
    )


@require_GET
def api_shipment(request, shipment_id: int):
    shipment = get_object_or_404(Shipment, pk=shipment_id)
    carrier = carriers.get_carrier()
    return JsonResponse({"ok": True, "shipment": carrier.tracking(shipment.tracking_number)})


@require_GET
def api_shipment_for_escrow(request, escrow_id: int):
    shipment = Shipment.objects.filter(escrow__on_chain_id=escrow_id).order_by("-created_at").first()
    if not shipment:
        return JsonResponse({"ok": True, "shipment": None})
    carrier = carriers.get_carrier()
    payload = carrier.tracking(shipment.tracking_number)
    payload["id"] = shipment.id
    try:
        state = escrow_state(escrow_id)
        payload["escrow_state"] = state["status"]
    except Exception:  # noqa: BLE001 — tracking must render even if RPC hiccups
        payload["escrow_state"] = None
    return JsonResponse({"ok": True, "shipment": payload})


@require_POST
def api_shipment_event(request, shipment_id: int):
    shipment = get_object_or_404(Shipment, pk=shipment_id)
    partner = shipment.provider
    wallet = _wallet(request)
    if partner and partner.owner_wallet and partner.owner_wallet.lower() != wallet.lower():
        return JsonResponse({"ok": False, "error": "not your shipment"}, status=403)
    body = _read_json(request)
    if body is None:
        return JsonResponse({"ok": False, "error": "invalid JSON body"}, status=400)
    try:
        event = carriers.get_carrier().advance(shipment, to_status=body.get("status"), note=body.get("note", ""))
    except ValueError as e:
        return JsonResponse({"ok": False, "error": str(e)}, status=400)
    return JsonResponse({"ok": True, "status": event.status, "simulated": True})


@require_POST
def api_carrier_attest(request, escrow_id: int):
    """Build, sign (Demo Carrier ML-DSA-87) and submit attestCarrierEvidence.

    The carrier account signs the canonical payload; the vault verifies it
    on-chain via pqcVerify. Returns the tx hash.
    """
    body = _read_json(request) or {}
    shipment = Shipment.objects.filter(escrow__on_chain_id=escrow_id).order_by("-created_at").first()
    if not shipment:
        return JsonResponse({"ok": False, "error": "no shipment for this escrow"}, status=404)

    carrier = carriers.get_carrier()
    payload_dict = carrier.tracking(shipment.tracking_number)
    payload_dict["escrow_id"] = str(escrow_id)
    if payload_dict.get("status") != "DELIVERED":
        return JsonResponse({"ok": False, "error": "shipment is not DELIVERED yet — advance the demo carrier first"}, status=400)

    import time

    from apps.blockchain.services.relayer import attest_carrier_evidence, carrier_nonce

    try:
        _, _, carrier_evm = carriers.demo_carrier_keypair()
        nonce = carrier_nonce(carrier_evm)
        issued_at = int(time.time())
        signed = carriers.sign_carrier_attestation(
            escrow_id, shipment.tracking_number, "DELIVERED", nonce, issued_at
        )
        signature = bytes.fromhex(signed["signature"])
        result = attest_carrier_evidence(
            escrow_id, shipment.tracking_number, "DELIVERED", issued_at, signature
        )
    except Exception as e:
        return JsonResponse({"ok": False, "error": str(e)}, status=500)

    payload_hash = "0x" + carriers.hash_attestation(signed["message"])

    VerificationRequest.objects.create(
        escrow=shipment.escrow,
        shipment=shipment,
        status="VERIFIED",
        requested_by=_wallet(request),
        input_payload={"message": signed["message"], "signature": signed["signature"], "issued_at": issued_at},
        result={"tx_hash": result["tx_hash"], "payload_hash": payload_hash},
        tx_hash=result["tx_hash"],
        completed_at=__import__("django").utils.timezone.now(),
        attestation_note="Demo Carrier ML-DSA-87 signature verified on-chain by SweeftVault (pqcVerify), bound to this escrow.",
    )
    if shipment.escrow:
        shipment.escrow.carrier_attested = True
        shipment.escrow.carrier_payload_hash = payload_hash
        shipment.escrow.save(update_fields=["carrier_attested", "carrier_payload_hash", "updated_at"])

    return JsonResponse({"ok": True, **result, "payload_hash": payload_hash})


@require_POST
def api_verification_payload(request):
    body = _read_json(request)
    if body is None:
        return JsonResponse({"ok": False, "error": "invalid JSON body"}, status=400)
    escrow_id = str(body.get("escrow_id", "")).strip()
    shipment = Shipment.objects.filter(escrow__on_chain_id=int(escrow_id) if escrow_id.isdigit() else None).order_by("-created_at").first()
    if not shipment:
        return JsonResponse({"ok": False, "error": "no shipment registered for this escrow"}, status=404)
    carrier = carriers.get_carrier()
    payload = carrier.tracking(shipment.tracking_number)
    payload["escrow_id"] = str(shipment.escrow.on_chain_id) if shipment.escrow else escrow_id
    try:
        payload = carriers.sign_carrier_payload(payload)
    except ValueError as e:
        return JsonResponse({"ok": False, "error": str(e)}, status=503)
    vr = VerificationRequest.objects.create(
        escrow=shipment.escrow,
        shipment=shipment,
        status="PENDING",
        requested_by=_wallet(request),
        input_payload=payload,
        attestation_note="ML-DSA-87 signed carrier payload — verified on-chain by SweeftVault.atttestCarrierEvidence; carrier data is SIMULATED Demo Carrier.",
    )
    # Hash of the canonical bytes is what the vault checks on-chain
    raw = carriers.canonical_carrier_message(payload).encode()
    from eth_utils import keccak

    return JsonResponse(
        {
            "ok": True,
            "verification_id": vr.id,
            "carrier_payload": json.dumps(payload),
            "payload_hash": "0x" + keccak(raw).hex(),
            "simulated": True,
        }
    )


# ---------------------------------------------------------------------------
# Partner API (API-key auth; automated carrier systems)
# ---------------------------------------------------------------------------


def _api_partner(request):
    key = request.headers.get("X-Api-Key", "")
    cred = PartnerApiCredential.verify_key(key)
    return cred.partner if cred else None


@csrf_exempt
@require_GET
def api_partner_shipments(request):
    partner = _api_partner(request)
    if not partner:
        return JsonResponse({"ok": False, "error": "invalid API key"}, status=401)
    include_chain = request.GET.get("include_escrow_state") == "1"
    shipments = Shipment.objects.filter(provider=partner).prefetch_related("events", "escrow")
    rows = []
    for s in shipments:
        row = {
            "id": s.id,
            "escrow_id": str(s.escrow.on_chain_id) if s.escrow else None,
            "tracking_number": s.tracking_number,
            "status": s.status,
            "simulation_scenario": s.simulation_scenario,
            "created_at": s.created_at.isoformat(),
            "updated_at": s.updated_at.isoformat(),
            "events": [
                {"status": e.status, "note": e.note, "timestamp": e.created_at.isoformat()}
                for e in s.events.all()
            ],
        }
        if include_chain and s.escrow:
            try:
                state = escrow_state(s.escrow.on_chain_id)
                row["escrow_state"] = state["status"]
            except Exception:  # noqa: BLE001
                row["escrow_state"] = None
        rows.append(row)
    return JsonResponse({"ok": True, "simulated": True, "shipments": rows})


@csrf_exempt
@require_POST
def api_partner_event(request, shipment_id: int):
    partner = _api_partner(request)
    if not partner:
        return JsonResponse({"ok": False, "error": "invalid API key"}, status=401)
    shipment = get_object_or_404(Shipment, pk=shipment_id, provider=partner)
    body = _read_json(request)
    if body is None:
        return JsonResponse({"ok": False, "error": "invalid JSON body"}, status=400)
    status_value = str(body.get("status") or "").upper()
    valid = {c[0] for c in Shipment.STATUS_CHOICES}
    if status_value not in valid:
        return JsonResponse({"ok": False, "error": f"status must be one of {sorted(valid)}"}, status=400)
    try:
        event = carriers.get_carrier().advance(shipment, to_status=status_value, note=body.get("note", "Partner-reported event"))
    except ValueError as e:
        return JsonResponse({"ok": False, "error": str(e)}, status=400)
    return JsonResponse({"ok": True, "status": event.status, "simulated": True})
