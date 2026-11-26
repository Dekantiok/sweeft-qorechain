"""Byte-identical copies of the Sweeft signed-message formats.

The Vault rebuilds these strings on-chain and verifies the ML-DSA-87
signature via QoreChain's `pqcVerify` precompile. If these formats ever
change, the on-chain contracts must change with them (they're versioned:
`sweeft-release-v1`, `sweeft-refund-v1`, `qorechain-msg-v1`).
"""

from __future__ import annotations


def release_message(vault: str, escrow_id: int, buyer: str, recipient: str, amount_wei: int, nonce: int) -> str:
    return (
        f"sweeft-release-v1|vault={vault.lower()}|escrow={escrow_id}|buyer={buyer.lower()}"
        f"|recipient={recipient.lower()}|amount={amount_wei}|nonce={nonce}"
    )


def refund_message(vault: str, escrow_id: int, buyer: str, recipient: str, amount_wei: int, nonce: int) -> str:
    return (
        f"sweeft-refund-v1|vault={vault.lower()}|escrow={escrow_id}|buyer={buyer.lower()}"
        f"|recipient={recipient.lower()}|amount={amount_wei}|nonce={nonce}"
    )


def signing_payload(message: str, chain_id: str) -> bytes:
    """The bytes QoreX signs for a dApp message (UTF-8)."""
    return f"qorechain-msg-v1|{chain_id}|{message}".encode("utf-8")
