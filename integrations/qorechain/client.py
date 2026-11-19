"""QoreChain network configuration and low-level clients.

All chain access in Sweeft goes through this package. Business logic must not
talk to RPC endpoints directly — use `integrations.qorechain.contracts` and
`integrations.qorechain.events` for reads, and prepare transactions for the
user's wallet (the server never signs for users).
"""

from __future__ import annotations

import functools
import os
from dataclasses import dataclass

from dotenv import load_dotenv

load_dotenv()


@dataclass(frozen=True)
class QoreChainNetwork:
    """Immutable network configuration."""

    network: str
    chain_id: str
    evm_chain_id: int
    rest_url: str
    rpc_url: str
    evm_rpc_url: str
    explorer_url: str
    pqc_verify_address: str
    pqc_key_status_address: str

    def explorer_tx(self, tx_hash: str) -> str:
        return f"{self.explorer_url}/tx/{tx_hash}"

    def explorer_address(self, address: str) -> str:
        return f"{self.explorer_url}/account/{address}"


def get_network() -> QoreChainNetwork:
    """Return the configured QoreChain network (testnet by default)."""
    return QoreChainNetwork(
        network=os.getenv("QORECHAIN_NETWORK", "testnet"),
        chain_id=os.getenv("QORECHAIN_CHAIN_ID", "qorechain-diana"),
        evm_chain_id=int(os.getenv("QORECHAIN_EVM_CHAIN_ID", "9800")),
        rest_url=os.getenv("QORECHAIN_REST_URL", "https://api-testnet.qore.host"),
        rpc_url=os.getenv("QORECHAIN_RPC_URL", "https://rpc-testnet.qore.host"),
        evm_rpc_url=os.getenv("QORECHAIN_EVM_RPC_URL", "https://evm-testnet.qore.host"),
        explorer_url=os.getenv("QORECHAIN_EXPLORER_URL", "https://explore.qore.network"),
        pqc_verify_address=os.getenv(
            "QORECHAIN_PQC_VERIFY_ADDRESS", "0x0000000000000000000000000000000000000a01"
        ),
        pqc_key_status_address=os.getenv(
            "QORECHAIN_PQC_KEY_STATUS_ADDRESS", "0x0000000000000000000000000000000000000a02"
        ),
    )


@functools.lru_cache(maxsize=1)
def get_evm_client():
    """Return a cached Web3 client for the EVM lane.

    Read-only usage: callers must never send raw signed transactions from the
    server for user operations. Deploy/relayer scripts use their own keys.
    """
    from web3 import Web3

    network = get_network()
    return Web3(Web3.HTTPProvider(network.evm_rpc_url))
