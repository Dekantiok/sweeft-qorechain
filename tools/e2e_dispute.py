#!/usr/bin/env python3
"""Sweeft — end-to-end dispute resolution on QoreChain Diana.

Runs the complete staked-resolver flow:
  1. Resolvers stake 20 QOR each (minimum stake)
  2. Buyer creates and funds an escrow, then raises a dispute (escrow freezes)
  3. Three eligible resolvers join the board (parties excluded)
  4. Two resolvers vote release -> 2-of-3 majority settles on-chain
  5. Voters claim their reward (10% of the platform fee each) from the pool
  6. Asserts: seller paid minus fee, treasury and pool split, rewards paid

Usage:
    .venv/bin/python tools/e2e_dispute.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

import qor_lib as lib  # noqa: E402

AMOUNT = 10**17  # 0.1 QOR
FEE_BPS = 200  # 2%
MIN_STAKE = 20 * 10**18  # 20 QOR


def _qor(wei: int) -> str:
    return f"{wei / 10**18:.6f}"


def main() -> None:
    w3 = lib.get_w3()
    buyer = lib.account(0)
    seller = lib.account(1)
    resolvers = [lib.account(i) for i in (3, 4, 5)]

    vault = lib.contract(w3, "SweeftVault")
    board = lib.contract(w3, "SweeftDisputeBoard")

    print("=" * 68)
    print("SWEEFT — DISPUTE RESOLUTION SCENARIO (Diana testnet)")
    print("=" * 68)
    print(f"buyer     {buyer.evm}")
    print(f"seller    {seller.evm}")
    for i, r in enumerate(resolvers):
        print(f"resolver{i + 1} {r.evm}")
    print()

    # ------------------------------------------------------------------
    print("[setup] funding + staking resolvers (min stake 20 QOR)")
    # Window value caps must cover the transfers (3 x 22 QOR to resolvers).
    lib.ensure_evm_window(
        buyer, blocks=8_000, max_txs=120, max_value=120_000_000, min_value=80_000_000
    )
    for r in resolvers:
        stake = board.functions.stakeOf(w3.to_checksum_address(r.evm)).call()
        if stake >= MIN_STAKE:
            print(f"      {r.evm[:10]}… already staked ({_qor(stake)} QOR)")
            continue
        balance = w3.eth.get_balance(w3.to_checksum_address(r.evm))
        if balance < MIN_STAKE + 10**18:
            lib.transfer_qor(w3, buyer, r.evm, MIN_STAKE + 2 * 10**18)
        lib.ensure_pqc_registered(r)
        lib.ensure_evm_window(r, blocks=4_000, max_txs=40, max_value=30_000_000, min_value=25_000_000)
        result = lib.send_evm_expect_success(w3, r, board.functions.stake(), value=MIN_STAKE, gas=300_000)
        print(f"      {r.evm[:10]}… staked 20 QOR ({result['hash'][:16]}…)")

    # ------------------------------------------------------------------
    print()
    print("[1/5] buyer creates and funds an escrow")
    escrow_id = vault.functions.escrowCount().call()
    deadline = w3.eth.get_block("latest")["timestamp"] + 86_400
    lib.send_evm_expect_success(
        w3, buyer, vault.functions.createEscrow(buyer.evm, seller.evm, deadline, AMOUNT),
        value=AMOUNT, gas=600_000,
    )
    print(f"      escrow #{escrow_id} funded with {_qor(AMOUNT)} QOR")

    print("[2/5] buyer raises a dispute — escrow freezes")
    dispute_id = board.functions.disputeCount().call()
    result = lib.send_evm_expect_success(w3, buyer, board.functions.openDispute(escrow_id), gas=400_000)
    status = vault.functions.getEscrow(escrow_id).call()[5]
    assert status == 5, f"escrow should be Disputed(5), got {status}"
    print(f"      dispute #{dispute_id} opened — tx {result['hash'][:18]}…")

    print("[3/5] three resolvers join the board")
    for i, r in enumerate(resolvers):
        result = lib.send_evm_expect_success(w3, r, board.functions.joinDispute(dispute_id), gas=400_000)
        print(f"      resolver{i + 1} joined ({result['hash'][:16]}…)")

    # ------------------------------------------------------------------
    print("[4/5] voting — two for release settles by majority")
    seller_before = w3.eth.get_balance(w3.to_checksum_address(seller.evm))
    fee = (AMOUNT * FEE_BPS) // 10_000
    pool_before = board.functions.rewardPool().call()

    for r in resolvers[:2]:
        lib.send_evm_expect_success(w3, r, board.functions.castVote(dispute_id, True), gas=600_000)
    print("      resolvers 1 & 2 voted RELEASE")

    time.sleep(3)
    seller_after = w3.eth.get_balance(w3.to_checksum_address(seller.evm))
    delta = seller_after - seller_before
    status = vault.functions.getEscrow(escrow_id).call()[5]
    pool_after = board.functions.rewardPool().call()

    print(f"      seller received {_qor(delta)} QOR (amount {_qor(AMOUNT)} - fee {_qor(fee)})")
    print(f"      reward pool: {_qor(pool_before)} -> {_qor(pool_after)} QOR (+30% of fee)")

    # ------------------------------------------------------------------
    print("[5/5] voters claim their rewards (10% of fee each)")
    expected_reward = (fee * 3000) // 10_000 // 3
    for r in resolvers[:2]:
        pool_before_claim = board.functions.rewardPool().call()
        lib.send_evm_expect_success(w3, r, board.functions.claimReward(dispute_id), gas=300_000)
        pool_after_claim = board.functions.rewardPool().call()
        claimed = pool_before_claim - pool_after_claim
        print(f"      {r.evm[:10]}… claimed {_qor(claimed)} QOR from the pool")
        assert claimed == expected_reward, f"expected {expected_reward}, got {claimed}"

    # ------------------------------------------------------------------
    print()
    print("=" * 68)
    print(f"escrow status      : {status} (2 = Completed)")
    print(f"seller delta       : {_qor(delta)} QOR (expected {_qor(AMOUNT - fee)})")
    print(f"resolver reward    : {_qor(expected_reward)} QOR each (10% of fee)")
    print(f"pool remaining     : {_qor(board.functions.rewardPool().call())} QOR")

    if status != 2 or delta != AMOUNT - fee:
        lib.die("final assertions failed")
    print()
    print("DISPUTE RESOLUTION SCENARIO: PASS")


if __name__ == "__main__":
    main()
