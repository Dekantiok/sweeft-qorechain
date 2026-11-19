#!/usr/bin/env python3
"""Sweeft — test the Django relay path for PQ release (browser equivalent).

Simulates precisely what the escrow web page does:
  1. (setup) create + fund a fresh escrow, buyer confirms receipt
  2. Ask Django for the exact release message        GET  /api/escrow/<id>/release-request/
  3. Sign it with the buyer's ML-DSA-87 key (exactly the bytes QoreX produces)
  4. Post the signature to Django                    POST /api/escrow/<id>/release/
  5. Django relays release(); the contract verifies the signature via pqcVerify
  6. Assert the seller was paid

Requires: Django dev server on 127.0.0.1:8001 and an open EVM window for the buyer.

Usage:
    .venv/bin/python tools/e2e_django_relay.py
"""

from __future__ import annotations

import base64
import json
import sys
import time
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from qorsdk import pqc_sign  # noqa: E402

import qor_lib as lib  # noqa: E402

DJANGO = "http://127.0.0.1:8001"
AMOUNT = 10**16  # 0.01 QOR


def http_json(method: str, url: str, payload: dict | None = None) -> dict:
    body = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=body, method=method)
    if body:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.loads(response.read())


def main() -> None:
    w3 = lib.get_w3()
    buyer = lib.account(0)
    seller = lib.account(1)
    vault = lib.contract(w3, "SweeftVault")

    print(f"buyer : {buyer.evm}")
    print(f"seller: {seller.evm}")
    print()

    # 1. Fresh escrow, funded, receipt confirmed -> release eligible immediately
    escrow_id = vault.functions.escrowCount().call()
    deadline = w3.eth.get_block("latest")["timestamp"] + 3_600
    lib.ensure_evm_window(buyer, blocks=2_000, max_txs=40, max_value=5_000_000)
    lib.send_evm_expect_success(
        w3,
        buyer,
        vault.functions.createEscrow(buyer.evm, seller.evm, deadline, AMOUNT),
        value=AMOUNT,
        gas=600_000,
    )
    lib.send_evm_expect_success(w3, buyer, vault.functions.confirmReceipt(escrow_id), gas=300_000)
    print(f"[1/4] escrow #{escrow_id} created, funded, receipt confirmed")

    # 2. Indexer pass so Django knows about it, then ask for the release message.
    #    The indexer stays a few blocks behind the tip (RPC replica lag), so poll.
    request = None
    for attempt in range(15):
        sync = http_json("POST", f"{DJANGO}/api/indexer/sync/")
        try:
            request = http_json("GET", f"{DJANGO}/api/escrow/{escrow_id}/release-request/")
            break
        except Exception:
            print(f"[2/4] escrow not visible yet (attempt {attempt + 1}), retrying…")
            time.sleep(5)
    if request is None:
        lib.die(f"escrow #{escrow_id} never became visible in the projection")
    print(f"[2/4] indexer sync done: {sync.get('handled')}")
    message = request["message"]
    print(f"      message ({len(message)}B): {message[:96]}…")
    print(f"      buyer_qor: {request['buyer_qor']}")

    # 3. Sign exactly as QoreX would (QoreSign message-signing-v1)
    payload = lib.pqc_signing_payload(message.encode(), request["chain_id"])
    signature = pqc_sign(buyer.pqc.secret_key, payload)
    print(f"[3/4] ML-DSA-87 signature over {len(payload)}B payload: {len(signature)}B")

    # 4. Post the signature; Django relays the release transaction
    seller_before = w3.eth.get_balance(w3.to_checksum_address(seller.evm))
    result = http_json(
        "POST",
        f"{DJANGO}/api/escrow/{escrow_id}/release/",
        {"signature_pq_b64": base64.b64encode(signature).decode()},
    )
    if not result.get("ok"):
        lib.die(f"relay failed: {result}")
    print(f"[4/4] relayed: tx {result['tx_hash']}")

    time.sleep(3)
    seller_after = w3.eth.get_balance(w3.to_checksum_address(seller.evm))
    delta = seller_after - seller_before
    status = vault.functions.getEscrow(escrow_id).call()[5]

    print()
    print("=" * 64)
    print(f"seller received: {delta} wei ({delta / 10**18:.6f} QOR)")
    print(f"escrow status  : {status} (2 = Completed)")
    if delta != AMOUNT or status != 2:
        lib.die("assertions failed")
    print("DJANGO RELAY RELEASE: PASS")


if __name__ == "__main__":
    main()
