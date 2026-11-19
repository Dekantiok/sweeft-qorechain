"""Management command: sync on-chain events into the local projection."""

from django.core.management.base import BaseCommand

from apps.blockchain.services.indexer import sync_all


class Command(BaseCommand):
    help = "Index new events from the deployed Sweeft contracts (idempotent)."

    def add_arguments(self, parser):
        parser.add_argument("--max-blocks", type=int, default=None, help="Limit the scan window")

    def handle(self, *args, **options):
        results = sync_all(max_blocks=options["max_blocks"])
        for name, count in results.items():
            self.stdout.write(f"{name:24s} {count} event(s) handled")
        self.stdout.write(self.style.SUCCESS("index sync complete"))
