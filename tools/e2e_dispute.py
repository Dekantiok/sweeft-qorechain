#!/usr/bin/env python3
"""Sweeft — end-to-end dispute resolution on QoreChain Diana (v6 board).

Runs the complete staked-resolver flow:
  1. Nine resolvers stake 21 QOR each (20 base + 100% of the 0.1 QOR escrow)
  2. Buyer creates and funds an escrow, then raises a dispute (escrow freezes,
     0.1 QOR raiser bond posted)
  3. After the join window, a random 3-resolver panel is drawn (selectPanel)
  4. Two panel members vote release -> 2-of-3 decision is RECORDED, funds do
     not move until the appeal window closes (2 days by default)
  5. After the appeal window, anyone finalizes -> seller is paid minus fee
  6. Voters claim their fixed fee (20% of the bond split across voters)

Note: the v6 windows are long by design (join 6h, voting 48h, appeal 2d) and
are DAO-controlled, so this script polls until each deadline passes. It
takes days on a live deployment — on a local fork the windows can be
shortened by the board owner before running.

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
MIN_STAKE = 21 * 10**18  # 20 QOR base + 100% of 0.1 QOR escrow (v6 near-value stake)
DISPUTE_BOND = 10**17  # 0.1 QOR (1% of escrow, 0.1 QOR floor)
RESOLVER_FEE_BPS = 2000  # 20% of the bond pays the panel
ZERO = "0x" + "0" * 40


def _qor(wei: int) -> str:
    return f"{wei / 10**18:.6f}"


def _wait_until(w3, timestamp: int, label: str, poll: int = 300) -> None:
    while True:
        now = w3.eth.get_block("latest")["timestamp"]
        if now >= timestamp:
            return
        print(f"      waiting for {label}: {timestamp - now}s remaining")
        time.sleep(min(poll, max(5, timestamp - now)))


def main() -> None:
    w3 = lib.get_w3()
    buyer = lib.account(0)
    seller = lib.account(1)
    resolvers = [lib.account(i) for i in range(3, 12)]  # 9 staked resolvers
    by_address = {r.evm.lower(): r for r in resolvers}

    vault = lib.contract(w3, "SweeftVault")
    board = lib.contract(w3, "SweeftDisputeBoard")

    print("=" * 68)
    print("SWEEFT — DISPUTE RESOLUTION SCENARIO (Diana testnet, v6)")
    print("=" * 68)
    print(f"buyer     {buyer.evm}")
    print(f"seller    {seller.evm}")
    for i, r in enumerate(resolvers):
        print(f"resolver{i + 1} {r.evm}")
    print()

    # ------------------------------------------------------------------
    print("[setup] funding + staking resolvers (min stake 20.1 QOR for a 0.1 QOR escrow)")
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
        print(f"      {r.evm[:10]}… staked {_qor(MIN_STAKE)} QOR ({result['hash'][:16]}…)")

    # ------------------------------------------------------------------
    print()
    print("[1/6] buyer creates and funds an escrow")
    escrow_id = vault.functions.escrowCount().call()
    deadline = w3.eth.get_block("latest")["timestamp"] + 86_400
    lib.send_evm_expect_success(
        w3, buyer, vault.functions.createEscrow(buyer.evm, seller.evm, deadline, AMOUNT),
        value=AMOUNT, gas=600_000,
    )
    print(f"      escrow #{escrow_id} funded with {_qor(AMOUNT)} QOR")

    print("[2/6] buyer raises a dispute — escrow freezes, bond posted")
    dispute_id = board.functions.disputeCount().call()
    result = lib.send_evm_expect_success(
        w3, buyer, board.functions.openDispute(escrow_id), value=DISPUTE_BOND, gas=400_000
    )
    status = vault.functions.getEscrow(escrow_id).call()[5]
    assert status == 5, f"escrow should be Disputed(5), got {status}"
    print(f"      dispute #{dispute_id} opened — tx {result['hash'][:18]}…")

    print("[3/6] waiting for the join window, then drawing the panel")
    dispute = board.functions.getDispute(dispute_id).call()
    # getDispute: escrowId, raiser, openedAt, joinEndsAt, votingEndsAt, unlockAt, ...
    _wait_until(w3, dispute[3], "join window to end")
    result = lib.send_evm_expect_success(w3, buyer, board.functions.selectPanel(dispute_id), gas=400_000)
    print(f"      panel drawn — tx {result['hash'][:18]}…")
    members = [m for m in board.functions.members(dispute_id).call() if m.lower() != ZERO]
    assert len(members) == 3, f"expected 3 panel members, got {len(members)}"
    panel = []
    for m in members:
        acct = by_address.get(m.lower())
        if acct is None:
            lib.die(f"panel member {m} is not one of the staked test accounts")
        panel.append(acct)
        print(f"      panel member {m[:10]}…")

    # ------------------------------------------------------------------
    print("[4/6] voting — two for release records the decision (funds frozen)")
    seller_before = w3.eth.get_balance(w3.to_checksum_address(seller.evm))
    fee = (AMOUNT * FEE_BPS) // 10_000

    for r in panel[:2]:
        lib.send_evm_expect_success(w3, r, board.functions.castVote(dispute_id, True), gas=600_000)
    print("      panel members 1 & 2 voted RELEASE")

    time.sleep(3)
    status = vault.functions.getEscrow(escrow_id).call()[5]
    assert status == 5, f"escrow must stay Disputed until finalize, got {status}"
    dispute = board.functions.getDispute(dispute_id).call()
    unlock_at = dispute[5]
    print(f"      decision recorded — escrow still Disputed, appeal window until {unlock_at}")

    print("[5/6] waiting for the appeal window, then finalizing")
    _wait_until(w3, unlock_at, "appeal window to end")
    result = lib.send_evm_expect_success(w3, buyer, board.functions.finalize(dispute_id), gas=600_000)
    print(f"      finalized — tx {result['hash'][:18]}…")

    seller_after = w3.eth.get_balance(w3.to_checksum_address(seller.evm))
    delta = seller_after - seller_before
    status = vault.functions.getEscrow(escrow_id).call()[5]
    print(f"      seller received {_qor(delta)} QOR (amount {_qor(AMOUNT)} - fee {_qor(fee)})")
    print(f"      reward pool: {_qor(board.functions.rewardPool().call())} QOR")

    # ------------------------------------------------------------------
    print("[6/6] voters claim their fixed fee (20% of the bond, split per voter)")
    expected_reward = ((DISPUTE_BOND * RESOLVER_FEE_BPS) // 10_000) // 2
    for r in panel[:2]:
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
    print(f"resolver reward    : {_qor(expected_reward)} QOR each")
    print(f"pool remaining     : {_qor(board.functions.rewardPool().call())} QOR")

    if status != 2 or delta != AMOUNT - fee:
        lib.die("final assertions failed")
    print()
    print("DISPUTE RESOLUTION SCENARIO: PASS")


if __name__ == "__main__":
    main()
