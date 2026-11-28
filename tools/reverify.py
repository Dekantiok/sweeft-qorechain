#!/usr/bin/env python3
"""Re-verify every recorded Sweeft transaction and contract against Diana.

Parses the full hashes in docs/proofs/tx-inventory.md plus the keeper attack
log (docs/proofs/keeper-2026-11-23.md), fetches each receipt over public RPC,
and checks the expected status. Also checks that the v8 contract addresses
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

# v8 stack, from docs/deployments.md
CONTRACTS = {
    "SweeftOracleRegistry": "0x76D4F6D164C688b319eE0A16003a9c06f5b1AB7A",
    "SweeftVault": "0x820CE1C670D26A2fF6ca5ce53f5a9EFdf3dC869a",
    "SweeftMarketplace": "0xf5cC7Bf4EECC160E23b4fF615E68D716bEFCd47C",
    "SweeftDisputeBoard": "0x50a74dD32647bcf456DcE09b76849C5EBD2A0508",
    "SweeftDAO2": "0x91d0eCCE908bec0FcF06fB8d419ad9edb43Cf59b",
}

# Keeper attack log: these are REFUSED transactions (status 0) on purpose.
ATTACK_TXS = {"0x531f3ba7561f669e0480f7124cebbe5a41425a998282e48d4618eb8cd92d0a66"}


def recorded_hashes() -> list[str]:
    hashes = set()
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
