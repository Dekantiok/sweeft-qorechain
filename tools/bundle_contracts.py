#!/usr/bin/env python3
"""Bundle contracts/src/*.sol into one file for the QCAI Contract Auditor.

Usage:
    .venv/bin/python tools/bundle_contracts.py

Writes docs/audit/stage-3/sweeft-combined.sol and a tarball of the sources.
"""

from __future__ import annotations

import tarfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "contracts" / "src"
OUT_DIR = REPO / "docs" / "audit" / "stage-3"
OUT = OUT_DIR / "sweeft-combined.sol"
TARBALL = OUT_DIR / "sweeft-contracts-stage3.tar.gz"

# Deterministic order: core vault first, then the rest.
ORDER = [
    "SweeftVault.sol",
    "SweeftMarketplace.sol",
    "SweeftOracleRegistry.sol",
    "SweeftDisputeBoard.sol",
    "SweeftDAO2.sol",
    "SweeftDAO.sol",
]


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    files = sorted(SRC.glob("*.sol"), key=lambda p: (ORDER.index(p.name) if p.name in ORDER else 99, p.name))

    chunks = []
    for path in files:
        chunks.append(f"// ============ {path.name} ============\n")
        chunks.append(path.read_text().rstrip() + "\n\n")
    OUT.write_text("".join(chunks))
    print(f"wrote {OUT.relative_to(REPO)} ({OUT.stat().st_size} bytes, {len(files)} files)")

    with tarfile.open(TARBALL, "w:gz") as tar:
        for path in files:
            tar.add(path, arcname=f"contracts/src/{path.name}")
    print(f"wrote {TARBALL.relative_to(REPO)} ({TARBALL.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
