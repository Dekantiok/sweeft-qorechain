"""Message builders for PQ signing — must match SweeftVault byte for byte.

The contract rebuilds these exact strings and verifies the buyer's ML-DSA-87
signature over `"qorechain-msg-v1|" + chain_id + "|" + message` (QoreSign
message-signing-v1 — the same payload QoreX's signArbitrary produces).
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


def verifier_attestation_message(
    chain_id: str,
    vault: str,
    registry: str,
    verifier: str,
    key_version: int,
    escrow_id: int,
    evidence_hash: str,
    issued_at: int,
    expires_at: int,
    nonce: int,
) -> str:
    """Verifier PQ attestation (v1) — must match SweeftVault._verifierMessage
    byte-for-byte, including the pinned key version from the registry."""
    return (
        f"sweeft-verifier-v1|chain={chain_id}|vault={vault.lower()}|registry={registry.lower()}"
        f"|verifier={verifier.lower()}|keyVersion={key_version}|escrow={escrow_id}"
        f"|evidence={evidence_hash.lower()}|issued={issued_at}|expires={expires_at}|nonce={nonce}"
    )


def signing_payload(message: str, chain_id: str) -> bytes:
    """The bytes QoreX signs for a dApp message (UTF-8)."""
    return f"qorechain-msg-v1|{chain_id}|{message}".encode("utf-8")
