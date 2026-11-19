"""Address helpers for QoreChain — bech32 (qor1...) <-> EVM (0x...) forms.

On QoreChain the qor1 and 0x forms are two encodings of the same 20 bytes.
"""

from __future__ import annotations

from eth_utils import to_checksum_address


def normalize_evm(address: str) -> str:
    """Return EIP-55 checksummed EVM address."""
    return to_checksum_address(address)


def is_valid_evm(address: str) -> bool:
    from web3 import Web3

    return Web3.is_address(address)
