"""Management command: seed the local projection from chain (demo bootstrap).

Sets each contract cursor to `--from-block` (default: the current stack's
deployment block) and runs the full indexer sync. Idempotent: processed
events are deduplicated by (tx_hash, log_index), so re-running only fetches
new blocks. This is how a fresh demo database (sqlite, no history) gets its
marketplace listings and escrows on first boot.

Usage:
    python manage.py seed_from_chain --from-block 10773353
"""

from __future__ import annotations

from django.core.management.base import BaseCommand

from apps.blockchain.services.indexer import CONTRACTS, sync_all


class Command(BaseCommand):
    help = "Bootstrap the projection from a chain block (fresh demo DBs)."

    def add_arguments(self, parser):
        parser.add_argument(
            "--from-block",
            type=int,
            required=True,
            help="Block to start indexing from (deployment block of the current stack)",
        )

    def handle(self, *args, **options):
        from apps.blockchain.models import IndexerCursor

        from_env = __import__("os").getenv("SWEEFT_INDEX_FROM_BLOCK")
        from_block = options["from_block"]
        if from_env and int(from_env) != from_block:
            self.stdout.write(
                self.style.WARNING(
                    f"SWEEFT_INDEX_FROM_BLOCK={from_env} differs from --from-block={from_block}; "
                    "using --from-block"
                )
            )

        for name in CONTRACTS:
            cursor, _ = IndexerCursor.objects.get_or_create(contract_name=name)
            cursor.last_processed_block = min(cursor.last_processed_block or 0, from_block)
            if cursor.last_processed_block < from_block:
                cursor.last_processed_block = from_block
            cursor.save(update_fields=["last_processed_block", "updated_at"])
            self.stdout.write(f"cursor {name:24s} -> {from_block}")

        results = sync_all()
        total = 0
        for name, count in results.items():
            self.stdout.write(f"{name:24s} {count} event(s) handled")
            total += count

        # Backfill display titles for demo fixture listings whose placeholder
        # URIs can never verify: chain URI basename -> catalog entry.
        from apps.blockchain.services.indexer import _catalog_entry
        from apps.marketplace.models import Listing

        backfilled = 0
        for listing in Listing.objects.filter(title__startswith="Listing #"):
            try:
                from apps.blockchain.services.indexer import _contract

                contract = _contract("SweeftMarketplace")
                if contract is None:
                    break
                on_chain = contract.functions.getListing(listing.on_chain_id).call()
                entry = _catalog_entry(on_chain[4])
                if entry.get("title"):
                    listing.title = entry["title"]
                    if entry.get("description"):
                        listing.description = entry["description"]
                    listing.save(update_fields=["title", "description"])
                    backfilled += 1
            except Exception as exc:
                self.stdout.write(self.style.WARNING(f"title backfill skipped for #{listing.on_chain_id}: {exc}"))
        if backfilled:
            self.stdout.write(self.style.SUCCESS(f"backfilled {backfilled} demo listing title(s)"))

        self.stdout.write(self.style.SUCCESS(f"seed complete ({total} events)"))
