#!/usr/bin/env python3
"""Propose registerCarrier via DAO2 (v6), vote with locked stake, execute.

v6 DAO rules (SweeftDAO2): propose() takes a target + allowlisted calldata, a
0.05 QOR proposer bond, and a voting period of 3-14 days. castVote() is
payable — the escrowed QOR is the voting power (minimum 0.01 QOR, quorum
0.03 QOR). Execution requires the 3-day voting period plus a 2-day timelock,
so this script waits (polling) until the proposal is executable. If the
carrier is already registered the script exits early (idempotent re-runs).
"""
import sys
import time

sys.path.insert(0, "tools")
import qor_lib as lib

VOTING_PERIOD = 3 * 24 * 3600  # MIN_VOTING_PERIOD
PROPOSER_BOND = 5 * 10**16  # 0.05 QOR
VOTE_STAKE = 3 * 10**16  # 0.03 QOR — meets quorum in a single vote

w3 = lib.get_w3()
deployer = lib.account(0)
carrier = lib.account(6)
vault = lib.contract(w3, "SweeftVault")
dao = lib.contract(w3, "SweeftDAO2")

print("carrier", carrier.evm)
if vault.functions.isCarrier(w3.to_checksum_address(carrier.evm)).call():
    print("already a carrier — nothing to do")
    sys.exit(0)

lib.ensure_evm_window(deployer, blocks=8000, max_txs=80, max_value=20_000_000, min_value=1_000_000)

call = vault.encodeABI(fn_name="registerCarrier", args=[w3.to_checksum_address(carrier.evm), "LOG-DEMO-001"])
title = "Register Demo Carrier LOG-DEMO-001"
desc = "Adds the Demo Carrier account as an authorized logistics carrier"
pid = dao.functions.proposalCount().call()
r = lib.send_evm_expect_success(
    w3,
    deployer,
    dao.functions.propose(
        w3.to_checksum_address(lib.contract_address("SweeftVault")), call, title, desc, VOTING_PERIOD
    ),
    value=PROPOSER_BOND,
    gas=600_000,
)
print("propose", r["hash"], "proposal", pid)

# Stake-weighted vote: 0.03 QOR of voting power, locked until the proposal finalizes.
r = lib.send_evm_expect_success(w3, deployer, dao.functions.castVote(pid, 1), value=VOTE_STAKE, gas=200_000)
print("vote (0.03 QOR stake)", r["hash"])

print(f"waiting for timelock (voting {VOTING_PERIOD}s + 2 days)…")
while True:
    if dao.functions.isExecutable(pid).call():
        break
    state = dao.functions.getProposal(pid).call()
    print(f"  proposal state={state[11]} — still waiting")
    time.sleep(3600)

r = lib.send_evm_expect_success(w3, deployer, dao.functions.execute(pid, desc), gas=400_000)
print("execute", r["hash"])
print("isCarrier now?", vault.functions.isCarrier(w3.to_checksum_address(carrier.evm)).call())
