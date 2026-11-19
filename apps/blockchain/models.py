"""Blockchain — indexer bookkeeping.

Every processed event is recorded here first; the unique (tx_hash, log_index)
constraint makes event processing idempotent across restarts and reorgs.
"""

from __future__ import annotations

from django.db import models


class IndexerCursor(models.Model):
    """Last fully processed block per contract, for resumable indexing."""

    contract_name = models.CharField(max_length=60, unique=True)
    contract_address = models.CharField(max_length=42, blank=True)
    last_processed_block = models.PositiveBigIntegerField(default=0)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"{self.contract_name} @ block {self.last_processed_block}"


class ProcessedEvent(models.Model):
    """Idempotency record: one row per on-chain log entry ever handled."""

    contract_name = models.CharField(max_length=60)
    event_name = models.CharField(max_length=60)
    tx_hash = models.CharField(max_length=80)
    log_index = models.PositiveIntegerField()
    block_number = models.PositiveBigIntegerField()
    payload = models.JSONField(default=dict, blank=True)
    processed_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["tx_hash", "log_index"], name="unique_event_per_log")
        ]
        indexes = [models.Index(fields=["contract_name", "block_number"])]

    def __str__(self) -> str:
        return f"{self.event_name} {self.tx_hash[:12]}…:{self.log_index}"
