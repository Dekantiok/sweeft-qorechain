#!/usr/bin/env python3
"""Sweeft — migrate the oracle registry from DAO v1 to DAO v2.

DAO v1's only call target is the oracle registry, so this is a real
governance action: propose `transferOwnership(dao2)`, vote, wait, execute.
After this, verifier approvals are governed by DAO v2, which can also reach
the vault (fee parameters) and the dispute board.

Usage:
    .venv/bin/python tools/migrate_registry_ownership.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

import qor_lib as lib  # noqa: E402

VOTING_PERIOD = 60  # seconds — short for the demo


def main() -> None:
    w3 = lib.get_w3()
    deployer = lib.account(0)

    dao_v1 = lib.contract(w3, "SweeftDAO")
    registry = lib.contract(w3, "SweeftOracleRegistry")
    dao2_address = lib.contract_address("SweeftDAO2")

    current_owner = registry.functions.owner().call()
    if current_owner.lower() == dao2_address.lower():
        print(f"registry already owned by DAO v2 ({dao2_address}) — nothing to do")
        return

    print(f"registry owner : {current_owner}")
    print(f"DAO v2         : {dao2_address}")
    print()

    lib.ensure_evm_window(deployer, blocks=2_000, max_txs=40, max_value=5_000_000)

    print("[1/3] proposing registry.transferOwnership(dao2) on DAO v1")
    call_data = registry.encodeABI(fn_name="transferOwnership", args=[w3.to_checksum_address(dao2_address)])
    title = "Migrate verifier governance to DAO v2"
    description = "Transfers the oracle registry to the multisig-capable DAO v2 governance"
    proposal_id = dao_v1.functions.proposalCount().call()
    result = lib.send_evm_expect_success(
        w3, deployer, dao_v1.functions.propose(call_data, title, description, VOTING_PERIOD), gas=500_000
    )
    print(f"      proposal #{proposal_id} — tx {result['hash']}")

    print("[2/3] voting for")
    result = lib.send_evm_expect_success(w3, deployer, dao_v1.functions.castVote(proposal_id, 1), gas=200_000)
    print(f"      vote tx {result['hash']}")

    print(f"[3/3] waiting {VOTING_PERIOD}s, then executing")
    time.sleep(VOTING_PERIOD + 5)
    result = lib.send_evm_expect_success(
        w3, deployer, dao_v1.functions.execute(proposal_id, description), gas=300_000
    )
    print(f"      execute tx {result['hash']}")

    new_owner = registry.functions.owner().call()
    print()
    print(f"registry owner now: {new_owner}")
    if new_owner.lower() != dao2_address.lower():
        lib.die("migration did not take effect")
    print("REGISTRY MIGRATION TO DAO v2: PASS")


if __name__ == "__main__":
    main()
