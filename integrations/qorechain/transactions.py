"""Transaction helpers — building unsigned EVM transactions for user wallets.

The server never signs user transactions. These helpers return unsigned
payloads (to, data, value) that the frontend hands to the user's wallet
(QoreX / MetaMask) inside an open EVM window, or that a relayer flow wraps
for authenticator-authorized calls.
"""

from __future__ import annotations


def encode_function_call(contract, function_name: str, args: list | None = None) -> str:
    """Encode calldata for a contract function call."""
    fn = getattr(contract.functions, function_name)
    return fn(*(args or [])).build_transaction({"gas": 0})["data"]


def unsigned_tx(to: str, data: str = "0x", value_wei: int = 0, gas: int | None = None) -> dict:
    """Assemble an unsigned transaction document for the UI / wallet."""
    tx = {"to": to, "data": data, "value": hex(value_wei)}
    if gas:
        tx["gas"] = hex(gas)
    return tx
