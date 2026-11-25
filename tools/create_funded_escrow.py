#!/usr/bin/env python3
"""Create one funded v6 escrow and STOP (no release) — demo/E2E fixture.

Seller lists a digital good, buyer purchases (escrow funded atomically).
The escrow stays Funded so the UI (mark delivered / confirm receipt /
dispute) and the Playwright harness have a live v6 escrow to exercise.
"""
import hashlib
import sys
import time

sys.path.insert(0, "tools")
import qor_lib as lib

PRICE = 10**17  # 0.1 QOR
METADATA_HASH = hashlib.sha256(b'{"title":"Sweeft demo funded escrow","condition":"new"}').digest()

w3 = lib.get_w3()
buyer = lib.account(0)
seller = lib.account(1)
vault = lib.contract(w3, "SweeftVault")
market = lib.contract(w3, "SweeftMarketplace")

lib.ensure_evm_window(buyer, blocks=3_600, max_txs=80, max_value=10_000_000)
lib.ensure_evm_window(seller, blocks=3_600, max_txs=40, max_value=5_000_000)

listing_id = market.functions.listingCount().call()
lib.send_evm_expect_success(
    w3, seller,
    market.functions.createListing(PRICE, 1, "https://sweeft.example/metadata/demo-funded.json", METADATA_HASH),
    gas=500_000,
)
print("listing", listing_id)

escrow_id = vault.functions.escrowCount().call()
deadline = w3.eth.get_block("latest")["timestamp"] + 172_800
r = lib.send_evm_expect_success(
    w3, buyer, market.functions.purchase(listing_id, deadline, PRICE, METADATA_HASH), value=PRICE, gas=800_000
)
e = vault.functions.getEscrow(escrow_id).call()
print("escrow", escrow_id, "status", e[5], "tx", r["hash"][:18])
assert e[5] == 1, "escrow must be Funded(1)"
print("FUNDED ESCROW READY:", escrow_id)
