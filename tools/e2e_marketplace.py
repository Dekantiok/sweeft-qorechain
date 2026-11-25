#!/usr/bin/env python3
"""Sweeft — complete market scenario on QoreChain Diana (the demo flow).

Runs the full commerce story across four contracts in one script:

  Setup    fund seller + verifier, register their PQ keys, open their windows
  DAO      propose approving the verifier, vote, execute (governance on-chain)
  Market   seller lists a laptop on-chain
  Buy      buyer purchases; escrow is created and funded atomically
  Deliver  seller marks the order delivered
  Oracle   verifier attests fulfilment evidence on-chain
  Settle   inspection window passes; buyer signs release with ML-DSA-87;
           the Vault verifies the signature on-chain and pays the seller

Accounts (all derived from the stored testnet mnemonic, testnet only):
  index 0  buyer (also deployer, has the EVM window)
  index 1  seller
  index 2  verifier

Usage:
    .venv/bin/python tools/e2e_marketplace.py
"""

from __future__ import annotations

import hashlib
import json
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from eth_abi import encode as abi_encode  # noqa: E402
from qorsdk import pqc_sign  # noqa: E402

import qor_lib as lib  # noqa: E402

PRICE = 10**17  # 0.1 QOR in wei (EVM lane is 18 decimals)
DELIVERY_WINDOW = 120  # seconds until release eligibility
# v6 DAO2: 3-day minimum voting period + 2-day timelock, 0.05 QOR proposer
# bond, stake-weighted votes (0.03 QOR quorum). The script polls until the
# proposal is executable — budget days, or rely on the idempotent skip below
# once the verifier is already authorized.
VOTING_PERIOD = 3 * 24 * 3600
PROPOSER_BOND = 5 * 10**16  # 0.05 QOR
VOTE_STAKE = 3 * 10**16  # 0.03 QOR — meets quorum in a single vote
START_FUNDS = 10**18  # 1 QOR in wei for each new account


def _qor(wei: int) -> str:
    return f"{wei / 10**18:.6f}"


def main() -> None:
    w3 = lib.get_w3()
    buyer = lib.account(0)
    seller = lib.account(1)
    verifier = lib.account(2)

    vault = lib.contract(w3, "SweeftVault")
    market = lib.contract(w3, "SweeftMarketplace")
    registry = lib.contract(w3, "SweeftOracleRegistry")
    dao = lib.contract(w3, "SweeftDAO2")

    print("=" * 70)
    print("SWEEFT — COMPLETE MARKET SCENARIO (Diana testnet)")
    print("=" * 70)
    print(f"buyer    {buyer.evm}")
    print(f"seller   {seller.evm}")
    print(f"verifier {verifier.evm}")
    print()

    # ------------------------------------------------------------------
    print("[setup] funding seller and verifier")
    lib.transfer_qor(w3, buyer, seller.evm, START_FUNDS)
    lib.transfer_qor(w3, buyer, verifier.evm, START_FUNDS)

    print("[setup] registering PQ keys (native lane)")
    lib.ensure_pqc_registered(seller)
    lib.ensure_pqc_registered(verifier)

    print("[setup] opening scoped EVM windows")
    lib.ensure_evm_window(seller, blocks=3_600, max_txs=40, max_value=5_000_000)
    lib.ensure_evm_window(verifier, blocks=3_600, max_txs=40, max_value=5_000_000)
    lib.ensure_evm_window(buyer, blocks=3_600, max_txs=80, max_value=10_000_000)

    # ------------------------------------------------------------------
    verifier_checksum = w3.to_checksum_address(verifier.evm)
    if registry.functions.isVerifier(verifier_checksum).call():
        print()
        print("[dao] verifier already authorized on-chain — skipping governance (idempotent)")
    else:
        print()
        print("[dao] proposing verifier approval")
        call_data = registry.encodeABI(fn_name="addVerifier", args=[verifier_checksum])
        title = "Approve oracle verifier for demo run"
        description = "Adds the Sweeft e2e demo verifier account to the oracle registry"
        proposal_id = dao.functions.proposalCount().call()
        result = lib.send_evm_expect_success(
            w3,
            buyer,
            dao.functions.propose(
                w3.to_checksum_address(lib.contract_address("SweeftOracleRegistry")),
                call_data,
                title,
                description,
                VOTING_PERIOD,
            ),
            value=PROPOSER_BOND,
            gas=500_000,
        )
        print(f"      proposal #{proposal_id} — tx {result['hash']}")

        print("[dao] casting stake-weighted vote (0.03 QOR locked as voting power)")
        result = lib.send_evm_expect_success(
            w3, buyer, dao.functions.castVote(proposal_id, 1), value=VOTE_STAKE, gas=200_000
        )
        print(f"      vote tx {result['hash']}")

        print("[dao] waiting for voting period + timelock (polling isExecutable)")
        while not dao.functions.isExecutable(proposal_id).call():
            time.sleep(3600)

        print("[dao] executing proposal (calls the oracle registry)")
        result = lib.send_evm_expect_success(
            w3, buyer, dao.functions.execute(proposal_id, description), gas=300_000
        )
        print(f"      execute tx {result['hash']}")
        if not registry.functions.isVerifier(verifier_checksum).call():
            lib.die("verifier was not added by the DAO execution")
        print("      verifier is now authorized on-chain ✓")

    # ------------------------------------------------------------------
    print()
    print("[market] seller creates the listing on-chain")
    metadata = json.dumps(
        {"title": "MacBook Pro 14", "condition": "used, excellent", "seller": seller.evm}
    )
    metadata_hash = hashlib.sha256(metadata.encode()).digest()
    metadata_uri = "https://sweeft.example/metadata/demo-laptop.json"
    listing_id = market.functions.listingCount().call()
    result = lib.send_evm_expect_success(
        w3,
        seller,
        market.functions.createListing(PRICE, 1, metadata_uri, metadata_hash),
        gas=500_000,
    )
    print(f"      listing #{listing_id} — tx {result['hash']}")

    # ------------------------------------------------------------------
    print()
    print("[buy] buyer purchases — escrow created and funded atomically")
    escrow_id = vault.functions.escrowCount().call()
    # v5 bounds the deadline to [1 day, 90 days]; use 2 days and then confirm
    # receipt (the buyer-confirmation release path).
    deadline = w3.eth.get_block("latest")["timestamp"] + 172_800
    result = lib.send_evm_expect_success(
        w3, buyer, market.functions.purchase(listing_id, deadline, PRICE, metadata_hash), value=PRICE, gas=800_000
    )
    print(f"      escrow #{escrow_id} — tx {result['hash']}")

    escrow = vault.functions.getEscrow(escrow_id).call()
    if escrow[5] != 1:
        lib.die(f"escrow not funded (status={escrow[5]})")
    print("      escrow Funded ✓")

    # ------------------------------------------------------------------
    print()
    print("[deliver] seller marks the order delivered")
    result = lib.send_evm_expect_success(w3, seller, vault.functions.markDelivered(escrow_id), gas=200_000)
    print(f"      tx {result['hash']}")

    print("[oracle] verifier attests fulfilment evidence on-chain")
    evidence_hash = hashlib.sha256(b"delivery photo + carrier receipt").digest()
    result = lib.send_evm_expect_success(
        w3, verifier, vault.functions.attestEvidence(escrow_id, evidence_hash), gas=300_000
    )
    print(f"      tx {result['hash']}")

    # ------------------------------------------------------------------
    print()
    print("[settle] buyer confirms receipt — release becomes eligible")
    result = lib.send_evm_expect_success(w3, buyer, vault.functions.confirmReceipt(escrow_id), gas=200_000)
    print(f"      tx {result['hash']}")
    if not vault.functions.isReleaseEligible(escrow_id).call():
        lib.die("escrow not release-eligible after confirmation")

    print("[settle] buyer signs the release message with ML-DSA-87 (QoreX format)")
    nonce = vault.functions.escrowNonce(escrow_id).call()
    message = lib.release_message(lib.contract_address("SweeftVault"), escrow_id, buyer.evm, seller.evm, PRICE, nonce)
    payload = lib.pqc_signing_payload(message)
    signature = pqc_sign(buyer.pqc.secret_key, payload)
    print(f"      nonce={nonce} message={len(message)}B payload={len(payload)}B signature={len(signature)}B")

    seller_before = w3.eth.get_balance(w3.to_checksum_address(seller.evm))
    result = lib.send_evm_expect_success(
        w3, buyer, vault.functions.release(escrow_id, signature), gas=8_000_000
    )
    print(f"      release tx {result['hash']}")

    seller_after = w3.eth.get_balance(w3.to_checksum_address(seller.evm))
    delta = seller_after - seller_before
    escrow = vault.functions.getEscrow(escrow_id).call()
    listing = market.functions.getListing(listing_id).call()

    print()
    print("=" * 70)
    print(f"seller received : {delta} wei ({_qor(delta)} QOR)")
    print(f"escrow status   : {escrow[5]} (2 = Completed)")
    print(f"listing status  : {listing[3]} (2 = Sold)")
    print(f"reputation hook : escrow #{escrow_id} completed — evidence attested by verifier")
    print()

    fee = (PRICE * 200) // 10_000  # 2% on release
    if delta != PRICE - fee or escrow[5] != 2:
        lib.die("final assertions failed")
    print("COMPLETE MARKET SCENARIO: PASS")


if __name__ == "__main__":
    main()
