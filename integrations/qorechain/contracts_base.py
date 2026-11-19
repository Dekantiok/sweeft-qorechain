"""ABI loading and contract factory helpers (no Django settings required)."""

from __future__ import annotations

import json
from pathlib import Path


def load_abi(artifact: Path) -> list:
    """Load the ABI from a Foundry artifact JSON file."""
    if not artifact.exists():
        raise FileNotFoundError(
            f"ABI artifact not found: {artifact}. Run `forge build` in contracts/ first."
        )
    with artifact.open() as fh:
        data = json.load(fh)
    return data["abi"]


def make_contract(web3, address: str, abi: list):
    """Create a checksummed Web3 contract handle."""
    return web3.eth.contract(address=web3.to_checksum_address(address), abi=abi)
