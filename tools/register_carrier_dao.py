#!/usr/bin/env python3
"""Propose registerCarrier via DAO2, vote, execute."""
import sys, time
sys.path.insert(0, "tools")
import qor_lib as lib

w3 = lib.get_w3()
deployer = lib.account(0)
carrier = lib.account(6)
vault = lib.contract(w3, "SweeftVault")
dao = lib.contract(w3, "SweeftDAO2")

print("carrier", carrier.evm)
print("isCarrier?", vault.functions.isCarrier(w3.to_checksum_address(carrier.evm)).call())

lib.ensure_evm_window(deployer, blocks=8000, max_txs=80, max_value=20_000_000, min_value=1_000_000)

call = vault.encodeABI(fn_name="registerCarrier", args=[w3.to_checksum_address(carrier.evm), "LOG-DEMO-001"])
title = "Register Demo Carrier LOG-DEMO-001"
desc = "Adds the Demo Carrier account as an authorized logistics carrier"
pid = dao.functions.proposalCount().call()
r = lib.send_evm_expect_success(w3, deployer, dao.functions.propose(w3.to_checksum_address(lib.contract_address("SweeftVault")), call, title, desc, 60), gas=600_000)
print("propose", r["hash"])
r = lib.send_evm_expect_success(w3, deployer, dao.functions.castVote(pid, 1), gas=200_000)
print("vote", r["hash"])
time.sleep(65)
r = lib.send_evm_expect_success(w3, deployer, dao.functions.execute(pid, desc), gas=400_000)
print("execute", r["hash"])
print("isCarrier now?", vault.functions.isCarrier(w3.to_checksum_address(carrier.evm)).call())
