#!/usr/bin/env python3
"""Register the Demo Carrier on-chain and create a partner profile."""
from __future__ import annotations
import sys
from pathlib import Path
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))
import qor_lib as lib

def main():
    w3 = lib.get_w3()
    deployer = lib.account(0)
    carrier = lib.account(6)
    vault = lib.contract(w3, "SweeftVault")
    print(f"carrier evm: {carrier.evm}")
    print(f"carrier qor: {carrier.cosmos}")
    # ensure funded + PQ registered + window
    bal = w3.eth.get_balance(w3.to_checksum_address(carrier.evm))
    if bal < 2 * 10**18:
        lib.transfer_qor(w3, deployer, carrier.evm, 2 * 10**18)
    lib.ensure_pqc_registered(carrier)
    lib.ensure_evm_window(carrier, blocks=4000, max_txs=40, max_value=10_000_000, min_value=1_000_000)
    # register if not already
    if not vault.functions.isCarrier(w3.to_checksum_address(carrier.evm)).call():
        result = lib.send_evm_expect_success(w3, deployer, vault.functions.registerCarrier(w3.to_checksum_address(carrier.evm), "LOG-DEMO-001"), gas=300_000)
        print("registered:", result["hash"])
    else:
        print("already registered")
    # seed partner profile
    import os
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings.development")
    import django
    django.setup()
    from apps.logistics.models import LogisticsPartner
    partner, created = LogisticsPartner.objects.get_or_create(
        provider_id="LOG-DEMO-001",
        defaults={
            "company_name": "Demo Carrier (simulated)",
            "email": "carrier@example.com",
            "settlement_wallet": carrier.evm,
            "status": "ACTIVE",
            "operating_locations": "Lagos, Abuja",
            "services": "Same-day delivery — Lagos — 0.02 QOR/item\nInter-state delivery — NG — 0.05 QOR/item",
        },
    )
    print(f"partner: {partner.company_name} [{partner.status}] created={created}")

if __name__ == "__main__":
    main()
