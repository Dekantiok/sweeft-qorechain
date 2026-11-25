#!/usr/bin/env python3
"""Bundle contracts/src/*.sol into one file for the QCAI Contract Auditor.

Usage:
    .venv/bin/python tools/bundle_contracts.py [stage]

Writes docs/audit/<stage>/sweeft-combined.sol and a tarball of the sources.
Defaults to stage-3 (historical); pass "stage-4" for the v6 audit.
"""

from __future__ import annotations

import sys
import tarfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "contracts" / "src"
STAGE = sys.argv[1] if len(sys.argv) > 1 else "stage-3"
OUT_DIR = REPO / "docs" / "audit" / STAGE
OUT = OUT_DIR / "sweeft-combined.sol"
TARBALL = OUT_DIR / f"sweeft-contracts-{STAGE.replace('stage-', '')}.tar.gz"

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
