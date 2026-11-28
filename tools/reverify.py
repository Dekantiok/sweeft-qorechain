#!/usr/bin/env python3
"""Re-verify every recorded Sweeft transaction and contract against Diana.

Parses the full hashes in docs/proofs/tx-inventory.md plus the keeper attack
log (docs/proofs/keeper-2026-11-23.md), fetches each receipt over public RPC,
and checks the expected status. Also checks that the live v9 contract addresses
in docs/deployments.md still have bytecode. Prints a summary like
"41 passed, 0 failed". Exit code is non-zero on any failure.

Usage: .venv/bin/python tools/reverify.py
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RPC = os.getenv("QORECHAIN_EVM_RPC_URL", "https://evm-testnet.qore.host")

# v9 stack (live since 27 Nov 2026), from docs/deployments.md
CONTRACTS = {
    "SweeftOracleRegistry": "0x35720a83daaa400ae404b20b3769d9afc56253fc",
    "SweeftVault": "0x21b8a243bf96340ebe5b78b296004f1bf76862ce",
    "SweeftMarketplace": "0x1d60eb9325a9c3da7b95f21171a2187b1480fb55",
    "SweeftDisputeBoard": "0x7f7c0f74f86dcc49e8373d2c140dfa5213b08001",
    "SweeftDAO2": "0x428370F58AbF859672EB4516ce81cF58EcDAC91A",
}

# v9 end-to-end releases (full hashes in docs/deployments.md)
V9_RELEASE_TXS = [
    "0xd24afb1680f59de25bc22a0385bbd32d98f57d5838be35863f7e7dd6149118a8",
    "0x0320db17d37d8f446e2d4a9ecc47c7fb885a011b8e42b2732ed95d2ec38f3617",
]

# Keeper attack log: these are REFUSED transactions (status 0) on purpose.
ATTACK_TXS = {"0x531f3ba7561f669e0480f7124cebbe5a41425a998282e48d4618eb8cd92d0a66"}


def recorded_hashes() -> list[str]:
    hashes = set(V9_RELEASE_TXS)
    for name in ("tx-inventory.md", "keeper-2026-11-23.md"):
        text = (REPO / "docs" / "proofs" / name).read_text()
        hashes.update(re.findall(r"0x[0-9a-f]{64}", text))
    return sorted(hashes)


def main() -> int:
    from web3 import Web3

    w3 = Web3(Web3.HTTPProvider(RPC, request_kwargs={"timeout": 15}))
    passed = failed = 0

    for tx_hash in recorded_hashes():
        try:
            receipt = w3.eth.get_transaction_receipt(tx_hash)
        except Exception as exc:
            print(f"FAIL {tx_hash[:14]} unreachable: {exc}")
            failed += 1
            continue
        status = int(receipt["status"])
        expected = 0 if tx_hash.lower() in ATTACK_TXS else 1
        if status == expected:
            passed += 1
            print(f"OK   {tx_hash[:14]} status={status} block={receipt['blockNumber']}")
        else:
            failed += 1
            print(f"FAIL {tx_hash[:14]} status={status}, expected {expected}")

    for name, address in CONTRACTS.items():
        code = w3.eth.get_code(Web3.to_checksum_address(address))
        if len(code) > 2:
            passed += 1
            print(f"OK   {name} bytecode present ({len(code)} bytes)")
        else:
            failed += 1
            print(f"FAIL {name} no bytecode at {address}")

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
