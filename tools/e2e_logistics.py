#!/usr/bin/env python3
"""E2E logistics (v5): physical listing -> purchase -> bound carrier attestation
-> PQ release with logistics payout.

The v5 vault binds a carrier attestation to (carrier, escrowId, tracking,
status, issuedAt, nonce) and only treats DELIVERED as fulfilment.
"""
import hashlib
import sys
import time

sys.path.insert(0, "tools")
import qor_lib as lib  # noqa: E402
from qorsdk import pqc_sign  # noqa: E402

PROVIDER_ID = "LOG-DEMO-001"


def canonical_attestation(provider_id, tracking, escrow_id, status, issued_at, nonce, *, vault="", carrier="", evidence_hash="0x" + "0" * 64):
    """v2 carrier message — must match SweeftVault._carrierMessage byte-for-byte."""
    import hashlib as _hashlib

    tracking_hash = _hashlib.sha256(tracking.encode()).hexdigest()
    # keccak256 of the tracking string (the vault hashes, not sha256s it)
    try:
        from eth_utils import keccak

        tracking_hash = keccak(tracking.encode()).hex()
    except Exception:
        tracking_hash = _hashlib.sha256(tracking.encode()).hexdigest()
    expires_at = issued_at + 7 * 24 * 3600
    evidence = (evidence_hash or "").lower().replace("0x", "").rjust(64, "0")[-64:]
    return (
        f"sweeft-carrier-v2|chain=qorechain-diana|vault={vault.lower()}|carrier={carrier.lower()}"
        f"|provider={provider_id}|escrow={escrow_id}|trackingHash=0x{tracking_hash}"
        f"|status={status}|evidence=0x{evidence}|issued={issued_at}|expires={expires_at}|nonce={nonce}"
    )


def main():
    w3 = lib.get_w3()
    buyer, seller, carrier = lib.account(0), lib.account(1), lib.account(6)
    vault = lib.contract(w3, "SweeftVault")
    market = lib.contract(w3, "SweeftMarketplace")

    for a in [buyer, seller, carrier]:
        lib.ensure_evm_window(a, blocks=8000, max_txs=80, max_value=20_000_000, min_value=1_000_000)

    # 1. seller creates physical listing: total 1.1 QOR (1.0 goods + 0.1 logistics)
    price = 11 * 10**17
    log_fee = 1 * 10**17
    meta_hash = hashlib.sha256(b"meta").digest()
    listing_id = market.functions.listingCount().call()
    r = lib.send_evm_expect_success(w3, seller, market.functions.createListingWithLogistics(
        price, 1, "https://example.com/meta.json", meta_hash, w3.to_checksum_address(carrier.evm), log_fee
    ), gas=600_000)
    print("listing", listing_id, r["hash"][:18])

    # 2. buyer purchases, pinning price + metadata hash (v5)
    escrow_id = vault.functions.escrowCount().call()
    deadline = w3.eth.get_block("latest")["timestamp"] + 172800
    r = lib.send_evm_expect_success(
        w3, buyer, market.functions.purchase(listing_id, deadline, price, meta_hash), value=price, gas=800_000
    )
    print("purchase -> escrow", escrow_id, r["hash"][:18])
    e = vault.functions.getEscrow(escrow_id).call()
    print("escrow logistics partner", e[11], "logistics amount", e[12])

    # 3. carrier signs the bound canonical message and attests on-chain
    tracking = "DEMO-LOG-1"
    status = "DELIVERED"
    issued_at = int(time.time())
    nonce = vault.functions.carrierNonce(w3.to_checksum_address(carrier.evm)).call()
    message = canonical_attestation(
        PROVIDER_ID, tracking, escrow_id, status, issued_at, nonce,
        vault=lib.contract_address("SweeftVault"), carrier=w3.to_checksum_address(carrier.evm),
    ).encode()
    sig = pqc_sign(carrier.pqc.secret_key, message)
    print("carrier sig len", len(sig))
    r = lib.send_evm_expect_success(
        w3, carrier, vault.functions.attestCarrierEvidence(
            escrow_id, tracking, status, bytes(32), issued_at, issued_at + 7 * 24 * 3600, sig
        ), gas=1_500_000
    )
    print("attestCarrierEvidence", r["hash"][:18])
    e = vault.functions.getEscrow(escrow_id).call()
    print("carrierAttested", e[13], "evidenceAttested", e[8], "delivered", e[6])

    # 4. buyer confirms receipt then PQ release
    r = lib.send_evm_expect_success(w3, buyer, vault.functions.confirmReceipt(escrow_id), gas=300_000)
    print("confirm", r["hash"][:18])

    from integrations.qorechain.messages import release_message

    nonce = vault.functions.escrowNonce(escrow_id).call()
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
    goods = price - log_fee
    fee_platform = goods * 200 // 10000
    print(f"seller delta {seller_after - seller_before} expected {goods - fee_platform}")
    print(f"carrier delta {carrier_after - carrier_before} expected {log_fee}")
    assert seller_after - seller_before == goods - fee_platform
    assert carrier_after - carrier_before == log_fee
    print("LOGISTICS E2E: PASS")


if __name__ == "__main__":
    main()
