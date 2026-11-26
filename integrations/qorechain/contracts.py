"""Contract address book and ABI loading for deployed Sweeft contracts.

ABIs prefer Foundry build artifacts (`contracts/out/<Contract>.sol/<Contract>.json`,
so the Django side and the contracts never drift) and fall back to the bundled
copies in `integrations/qorechain/abi/` for deployed services with no forge
available (see `contracts_base.load_abi`). Keep the bundled copies in sync
after every `forge build` (`tools/bundle_contracts.py`).
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from django.conf import settings

from .client import get_network
from .contracts_base import load_abi, make_contract


def contracts_root() -> Path:
    return Path(settings.BASE_DIR) / "contracts"


def artifact_path(contract_name: str) -> Path:
    return contracts_root() / "out" / f"{contract_name}.sol" / f"{contract_name}.json"


ADDRESS_ENV = {
    "SweeftVault": "SWEEFT_VAULT_ADDRESS",
    "SweeftMarketplace": "SWEEFT_MARKETPLACE_ADDRESS",
    "SweeftOracleRegistry": "SWEEFT_ORACLE_REGISTRY_ADDRESS",
    # Legacy: superseded by SweeftDAO2; only read during historical backfill.
    "SweeftDAO": "SWEEFT_DAO_ADDRESS",
    "SweeftDAO2": "SWEEFT_DAO2_ADDRESS",
    "SweeftDisputeBoard": "SWEEFT_DISPUTE_BOARD_ADDRESS",
}


def contract_address(contract_name: str) -> str | None:
    env_key = ADDRESS_ENV.get(contract_name)
    if not env_key:
        raise KeyError(f"Unknown contract {contract_name}")
    return os.getenv(env_key) or None


def deployed_contract(contract_name: str):
    """Return a Web3 contract handle for reads, or None when not deployed."""
    address = contract_address(contract_name)
    if not address:
        return None
    abi = load_abi(artifact_path(contract_name))
    return make_contract(get_evm_client(), address, abi)
