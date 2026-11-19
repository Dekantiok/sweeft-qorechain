"""Block event indexing for Sweeft contracts.

The chain is the source of truth; PostgreSQL is a searchable projection.
The indexer is idempotent: each event is keyed by (tx_hash, log_index) so
re-processing a block range never double-counts.

QoreChain note: the public RPC caps `eth_getLogs` at 10,000 blocks, so all
scans are chunked automatically.
"""

from __future__ import annotations

from dataclasses import dataclass

MAX_BLOCK_RANGE = 9_000  # stay under the public RPC 10k cap


@dataclass(frozen=True)
class ChainEvent:
    """A normalized contract event."""

    contract: str
    event: str
    args: dict
    block_number: int
    tx_hash: str
    log_index: int

    @property
    def key(self) -> str:
        """Globally unique event key for idempotent processing."""
        return f"{self.tx_hash}:{self.log_index}"


def fetch_events(contract, event_name: str, from_block: int, to_block: int) -> list[ChainEvent]:
    """Fetch a contract event over a block range, chunked for the RPC cap."""
    events: list[ChainEvent] = []
    start = from_block
    while start <= to_block:
        end = min(start + MAX_BLOCK_RANGE - 1, to_block)
        raw = getattr(contract.events, event_name).get_logs(fromBlock=start, toBlock=end)
        for entry in raw:
            events.append(
                ChainEvent(
                    contract=contract.address,
                    event=event_name,
                    args=dict(entry["args"]),
                    block_number=entry["blockNumber"],
                    tx_hash=entry["transactionHash"].hex(),
                    log_index=entry["logIndex"],
                )
            )
        start = end + 1
    return events
