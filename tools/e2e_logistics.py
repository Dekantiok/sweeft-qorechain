#!/usr/bin/env python3
"""E2E logistics: physical listing -> purchase -> carrier attestation -> release with logistics payout."""
import hashlib, sys, time
sys.path.insert(0, "tools")
import qor_lib as lib
from qorsdk import pqc_sign

def main():
    w3 = lib.get_w3()
    buyer, seller, carrier = lib.account(0), lib.account(1), lib.account(6)
    vault = lib.contract(w3, "SweeftVault")
    market = lib.contract(w3, "SweeftMarketplace")

    # fund carrier already done; ensure windows
    for a in [buyer, seller, carrier]:
        lib.ensure_evm_window(a, blocks=8000, max_txs=80, max_value=20_000_000, min_value=1_000_000)

    # 1. seller creates physical listing: total 1.1 QOR (1.0 goods + 0.1 logistics)
    price = 11 * 10**17
    fee = 1 * 10**17
    listing_id = market.functions.listingCount().call()
    r = lib.send_evm_expect_success(w3, seller, market.functions.createListingWithLogistics(
        price, 1, "https://example.com/meta.json", hashlib.sha256(b"meta").digest(), w3.to_checksum_address(carrier.evm), fee
    ), gas=600_000)
    print("listing", listing_id, r["hash"][:18])

    # 2. buyer purchases
    escrow_id = vault.functions.escrowCount().call()
    deadline = w3.eth.get_block("latest")["timestamp"] + 86400
    r = lib.send_evm_expect_success(w3, buyer, market.functions.purchase(listing_id, deadline), value=price, gas=800_000)
    print("purchase -> escrow", escrow_id, r["hash"][:18])
    e = vault.functions.getEscrow(escrow_id).call()
    print("escrow logistics partner", e[11], "amount", e[12])

    # 3. carrier signs canonical payload and attests on-chain
    # canonical: sweeft-carrier-v1|provider|tracking|escrow|status|issued|events
    payload_str = f"sweeft-carrier-v1|LOG-DEMO-001|DEMO-LOG-1|{escrow_id}|DELIVERED|{int(time.time()*1000)}|CREATED@1000,DELIVERED@2000"
    payload = payload_str.encode()
    payload_hash = __import__("eth_utils").keccak(payload)
    sig = pqc_sign(carrier.pqc.secret_key, payload)
    print("carrier sig len", len(sig), "payloadHash", payload_hash.hex()[:18])

    r = lib.send_evm_expect_success(w3, carrier, vault.functions.attestCarrierEvidence(escrow_id, payload_hash, sig, payload), gas=1_500_000)
    print("attestCarrierEvidence", r["hash"][:18])
    e = vault.functions.getEscrow(escrow_id).call()
    print("carrierAttested", e[14], "evidenceAttested", e[8], "delivered", e[6])

    # 4. buyer confirms receipt then PQ release
    r = lib.send_evm_expect_success(w3, buyer, vault.functions.confirmReceipt(escrow_id), gas=300_000)
    print("confirm", r["hash"][:18])

    from integrations.qorechain.messages import release_message
    import os
    nonce = vault.functions.pqcNonce(w3.to_checksum_address(buyer.evm)).call()
    msg = release_message(lib.contract_address("SweeftVault"), escrow_id, buyer.evm, seller.evm, price, nonce)
    payload2 = lib.pqc_signing_payload(msg.encode())
    sig2 = pqc_sign(buyer.pqc.secret_key, payload2)

    seller_before = w3.eth.get_balance(w3.to_checksum_address(seller.evm))
    carrier_before = w3.eth.get_balance(w3.to_checksum_address(carrier.evm))
    r = lib.send_evm_expect_success(w3, buyer, vault.functions.release(escrow_id, sig2), gas=8_000_000)
    print("release", r["hash"][:18])
    time.sleep(3)
    seller_after = w3.eth.get_balance(w3.to_checksum_address(seller.evm))
    carrier_after = w3.eth.get_balance(w3.to_checksum_address(carrier.evm))
    goods = price - fee
    fee_platform = goods * 200 // 10000
    print(f"seller delta {seller_after - seller_before} expected {goods - fee_platform}")
    print(f"carrier delta {carrier_after - carrier_before} expected {fee}")
    assert seller_after - seller_before == goods - fee_platform
    assert carrier_after - carrier_before == fee
    print("LOGISTICS E2E: PASS")

if __name__ == "__main__":
    main()
