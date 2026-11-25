#!/usr/bin/env python3
"""Create one release-ELIGIBLE v6 escrow and STOP (no release) — E2E fixture.

Full path minus the final release: list -> purchase -> markDelivered ->
verifier attests -> buyer confirmReceipt. The escrow becomes
release-eligible; the Playwright harness checks /api/escrow/<id>/release-request/
returns a buildable release message for it.
"""
import hashlib
import sys

sys.path.insert(0, "tools")
import qor_lib as lib

PRICE = 10**17  # 0.1 QOR
METADATA_HASH = hashlib.sha256(b'{"title":"Sweeft demo eligible escrow","condition":"new"}').digest()

w3 = lib.get_w3()
buyer = lib.account(0)
seller = lib.account(1)
verifier = lib.account(2)
vault = lib.contract(w3, "SweeftVault")
market = lib.contract(w3, "SweeftMarketplace")

for acct in (buyer, seller, verifier):
    lib.ensure_evm_window(acct, blocks=3_600, max_txs=80, max_value=10_000_000)

listing_id = market.functions.listingCount().call()
lib.send_evm_expect_success(
    w3, seller,
    market.functions.createListing(PRICE, 1, "https://sweeft.example/metadata/demo-eligible.json", METADATA_HASH),
    gas=500_000,
)
print("listing", listing_id)

escrow_id = vault.functions.escrowCount().call()
deadline = w3.eth.get_block("latest")["timestamp"] + 172_800
lib.send_evm_expect_success(
    w3, buyer, market.functions.purchase(listing_id, deadline, PRICE, METADATA_HASH), value=PRICE, gas=800_000
)
print("escrow", escrow_id, "funded")

lib.send_evm_expect_success(w3, seller, vault.functions.markDelivered(escrow_id), gas=200_000)
print("marked delivered")
lib.send_evm_expect_success(
    w3, verifier, vault.functions.attestEvidence(escrow_id, hashlib.sha256(b"e2e-eligible").digest()), gas=300_000
)
print("attested")
lib.send_evm_expect_success(w3, buyer, vault.functions.confirmReceipt(escrow_id), gas=200_000)
print("confirmed")

assert vault.functions.isReleaseEligible(escrow_id).call(), "escrow must be release-eligible"
print("ELIGIBLE ESCROW READY:", escrow_id)
