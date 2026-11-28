#!/usr/bin/env python3
"""Seed 100 products + multi-actor activity on Diana (v9).

Roles (mnemonic indices):
  Sellers:   1, 4, 5, 6, 7, 8
  Buyers:    0 (deployer), 11, 12, 13
  Resolvers: 14, 15, 16, 17, 18  (20 QOR stake each)
  Carrier:   SWEEFT_CARRIER_ADDRESS (existing)
  Verifier:  SWEEFT_VERIFIER_ADDRESS (existing)

Steps (idempotent-ish, resumable):
  phase1: fund wallets, register PQ keys, open windows, create 100 listings
  phase2: purchases, attestations, releases, one dispute, DAO proposal

Usage: .venv/bin/python tools/seed_marketplace_100.py [phase1|phase2|all]
"""
from __future__ import annotations
import hashlib, json, os, sys, random
from pathlib import Path
from dotenv import load_dotenv

REPO = Path(__file__).resolve().parent.parent
load_dotenv(REPO / ".env")
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tools"))
import qor_lib as lib

PUBLIC_BASE = "https://sweeft-qorechain.onrender.com"
META_DIR = REPO / "static/metadata/listings"

SELLERS = [1, 4, 5, 6, 7, 8]
BUYERS = [0, 11, 12, 13]
RESOLVERS = [14, 15, 16, 17, 18]

PRODUCTS = [
    ("physical", "Wireless Noise-Cancelling Headphones", "Over-ear Bluetooth 5.3 headphones with 40h battery, sealed in box."),
    ("physical", "Mechanical Keyboard 75%", "Hot-swappable 75% keyboard, silent linear switches, QMK/VIA."),
    ("physical", "Ergonomic Desk Lamp", "Adjustable brass desk lamp with warm dimmable LED."),
    ("physical", "Portable USB-C Hub", "7-in-1 hub: HDMI 4K, 2xUSB-C PD 100W, SD reader."),
    ("physical", "Laptop Stand Aluminium", "Foldable CNC aluminium stand, fits 10-16 inch laptops."),
    ("physical", "Ceramic Pour-Over Set", "Hand-glazed ceramic dripper + carafe, 600ml."),
    ("physical", "Trail Backpack 25L", "Water-resistant roll-top backpack with padded 15in sleeve."),
    ("physical", "Smart Plug 4-Pack", "Wi-Fi smart plugs with energy monitoring, voice assistant ready."),
    ("physical", "Leather Card Wallet", "Full-grain leather bifold, RFID shielding, 8 card slots."),
    ("physical", "Desk Organiser Oak", "Solid oak desk organiser with cable routing and phone dock."),
    ("digital", "Software Licence Pro Key", "One-year pro licence for photo editing suite, delivered by email."),
    ("digital", "UI Kit Design Assets", "480 component Figma kit with auto-layout and tokens."),
    ("digital", "E-book: Quantum Safety", "120-page ebook on post-quantum migration, PDF + EPUB."),
    ("digital", "Game Key Steam", "Sealed activation key for indie adventure, delivered in-chat."),
    ("digital", "Music Sample Pack", "2GB royalty-free sample pack, WAV 24-bit."),
    ("digital", "Notion Template Bundle", "10 productivity templates with setup guide."),
    ("digital", "Icon Pack 2000", "2000 SVG icons, SaaS-ready, MIT licence."),
    ("digital", "Video LUTs Collection", "35 cinematic LUTs for DaVinci/Premiere."),
    ("digital", "Data Analysis Course", "6h video course: Python + pandas + stats, lifetime access."),
    ("digital", "Fonts Family Display", "Display serif family, 8 weights, OTF/WOFF2."),
    ("service", "Smart-Contract Audit", "Solidity security review with written report, 5-day turnaround."),
    ("service", "Logo Design Package", "3 logo concepts + source files, 2 revision rounds."),
    ("service", "Website Security Audit", "Web app security audit with remediation call."),
    ("service", "Tutoring: Cryptography", "Two 90-min sessions on ML-KEM / ML-DSA fundamentals."),
    ("service", "Resume Review + Mock Interview", "CV rewrite and one mock interview session."),
    ("service", "Motion Graphics Intro", "Animated logo intro, 5s, 4K render."),
    ("service", "Containerisation Workshop", "Half-day Docker/K8s workshop for a team of 4."),
    ("service", "Data Pipeline Setup", "ETL pipeline setup with documentation."),
    ("service", "Translations EN-DE", "10,000-word technical translation, native speaker."),
    ("service", "Voiceover Recording", "30 min studio voiceover, broadcast quality."),
]

def transfer_uqor(w3, sender, to_evm, amount_uqor):
    """EVM-lane QOR transfer with correct wei conversion (1 uqor = 1e12 wei)."""
    eth = w3.eth.account.from_key(sender.private_key_hex)
    tx = {"from": eth.address, "to": w3.to_checksum_address(to_evm),
          "value": int(amount_uqor) * 10**12, "gas": 100_000,
          "gasPrice": w3.eth.gas_price,
          "nonce": w3.eth.get_transaction_count(eth.address, "pending"),
          "chainId": 9800}
    signed = eth.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(getattr(signed, "raw_transaction", None) or signed.rawTransaction)
    r = w3.eth.wait_for_transaction_receipt(h, timeout=90)
    assert r.status == 1, f"transfer reverted {h.hex()}"
    return h.hex()

def price_for(cat, i):
    """Return price in wei (contract uses wei). Values are uqor-scale numbers
    times 1e12 so displayed QOR prices are sane."""
    rng = random.Random(1000 + i)
    if cat == "physical": uqor = rng.randint(50_000, 2_000_000)
    elif cat == "digital": uqor = rng.randint(20_000, 500_000)
    else: uqor = rng.randint(100_000, 1_500_000)
    return uqor * 10**12

def main():
    phase = sys.argv[1] if len(sys.argv) > 1 else "all"
    w3 = lib.get_w3()
    market = lib.contract(w3, "SweeftMarketplace")
    vault = lib.contract(w3, "SweeftVault")
    carrier = os.getenv("SWEEFT_CARRIER_ADDRESS", "0xd2908Fd85fc5D5141AD2Bdd3913394245236Ec41")
    deployer = lib.account(0)
    print(f"phase={phase} market={market.address} carrier={carrier}")
    lib.ensure_evm_window(deployer, blocks=17280, max_txs=1000, max_value=300_000_000,
                          min_txs=500, min_value=250_000_000)
    def acct(i): return lib.account(i)

    if phase in ("phase1", "all"):
        # ---- funding ----
        fund_plan = {}
        for i in RESOLVERS: fund_plan[i] = 21_500_000  # 20 stake + float
        for i in [11, 12, 13]: fund_plan[i] = 5_000_000
        for i in [7, 8]: fund_plan[i] = 2_000_000
        for idx, amt in fund_plan.items():
            bal = lib.balance_uqor(acct(idx).cosmos)
            if bal < amt:
                need = amt - bal
                print(f"fund idx{idx} +{need/1e6:.2f} QOR")
                transfer_uqor(w3, deployer, acct(idx).evm, need)
            import time as _time; _time.sleep(8)
            lib.ensure_pqc_registered(acct(idx))
            lib.ensure_evm_window(acct(idx), blocks=17280, max_txs=500,
                                 max_value=200_000_000, min_txs=100, min_value=50_000_000)
        # sellers idx 1,4,5,6 already funded; register + windows
        for i in SELLERS + BUYERS:
            a = acct(i)
            lib.ensure_pqc_registered(a)
            lib.ensure_evm_window(a, blocks=17280, max_txs=500,
                                 max_value=200_000_000, min_txs=100, min_value=50_000_000)

        # ---- listings ----
        META_DIR.mkdir(parents=True, exist_ok=True)
        existing = int(market.functions.listingCount().call())
        print(f"existing listings: {existing}")
        prog = Path("/tmp/opencode/seed_progress.json")
        start = 0
        if prog.exists():
            try: start = int(json.loads(prog.read_text()).get("next_n", 0))
            except Exception: start = 0
        print(f"resume from n={start}")
        created = []
        for n in range(start, 100):
            cat, title, desc = PRODUCTS[n % len(PRODUCTS)]
            seller_idx = SELLERS[n % len(SELLERS)]
            seller = acct(seller_idx)
            seller_leg = seller_idx % 3
            slug = f"seed-{n:03d}-{cat}"
            meta = {"title": title, "description": desc, "category": cat,
                    "seller_index": seller_idx, "seed": n, "sweeft_metadata_version": 1}
            raw = json.dumps(meta, sort_keys=True, separators=(",", ":")).encode()
            digest = hashlib.sha256(raw).hexdigest()
            (META_DIR / f"{slug}.json").write_bytes(raw)
            uri = f"{PUBLIC_BASE}/static/metadata/listings/{slug}.json"
            price = price_for(cat, n)
            deadline = w3.eth.get_block("latest")["timestamp"] + 7 * 24 * 3600
            if cat == "physical" and carrier:
                log_fee = price // 10
                tx = lib.send_evm_expect_success(w3, seller, market.functions.createListingWithLogistics(
                    price, 1, uri, "0x" + digest, carrier, log_fee))
            else:
                tx = lib.send_evm_expect_success(w3, seller, market.functions.createListing(
                    price, 1, uri, "0x" + digest))
            created.append(tx["hash"])
            prog.write_text(json.dumps({"next_n": n + 1}))
            print(f"listing {n:03d} seller={seller_idx} cat={cat} price={price/1e6:.4f} tx={tx['hash'][:18]}", flush=True)
        print(f"created {len(created)} listings")

    if phase in ("phase2", "all"):
        from qorsdk import pqc_sign
        board = lib.contract(w3, "SweeftDisputeBoard")
        dao = lib.contract(w3, "SweeftDAO2")
        registry = lib.contract(w3, "SweeftOracleRegistry")
        verifier = acct(2)  # registered verifier 0x9E97...
        base = 4  # first new listing id (fixtures 0-3 existed)

        # Resolvers stake 20.5 QOR each
        for i in RESOLVERS:
            r = acct(i)
            if int(board.functions.stakeOf(r.evm).call()) == 0:
                lib.send_evm_expect_success(w3, r, board.functions.stake(), value=20_500_000 * 10**12)
                print(f"resolver idx{i} staked")

        def purchase(buyer_idx, listing_id, price_wei, meta_hash_hex):
            buyer = acct(buyer_idx)
            deadline = w3.eth.get_block("latest")["timestamp"] + 7 * 24 * 3600
            return lib.send_evm_expect_success(w3, buyer, market.functions.purchase(
                listing_id, deadline, price_wei, meta_hash_hex), value=price_wei, gas=2_000_000)

        # 10 complete lifecycles + 6 funded/eligible + 1 dispute
        listings_info = []
        for n in range(17):
            lid = base + n
            det = market.functions.getListing(lid).call()
            if int(det[3]) != 1:  # 1=Active; skip already-purchased (resume)
                # sequential seeding: escrow ids mirror listing ids here
                listings_info.append((n, lid, lid, BUYERS[n % len(BUYERS)]))
                print(f"skip listing {lid} (status {det[3]}) recovered escrow {lid}", flush=True)
                continue
            price = int(det[1]); mhash = "0x" + bytes(det[5]).hex()
            buyer_idx = BUYERS[n % len(BUYERS)]
            tx = purchase(buyer_idx, lid, price, mhash)
            eid = int(tx.get("escrow_id", 0)) if isinstance(tx, dict) else 0
            # derive escrow id from receipt event if helper doesn't return it
            if not eid:
                rc = w3.eth.get_transaction_receipt(tx["hash"])
                for raw_log in rc.logs:
                    try:
                        log = market.events.ListingPurchased().process_log(raw_log)
                        eid = int(log["args"]["escrowId"])
                    except Exception:
                        continue
            listings_info.append((n, lid, eid, buyer_idx))
            print(f"purchased listing {lid} -> escrow {eid} by buyer {buyer_idx}", flush=True)

        for (n, lid, eid, buyer_idx) in listings_info[:10]:
            if int(vault.functions.getEscrow(eid).call()[5]) == 2:
                print(f"skip settled escrow {eid}", flush=True)
                continue
            buyer = acct(buyer_idx)
            lib.send_evm_expect_success(w3, buyer, vault.functions.confirmReceipt(eid))
            ev = w3.keccak(text=f"evidence-{eid}")
            lib.submit_pq_attestation(w3, vault, registry, verifier, eid, bytes(ev), submitter=buyer)
            nonce = int(vault.functions.escrowNonce(eid).call())
            st = vault.functions.getEscrow(eid).call()
            msgb = lib.release_message(vault.address, eid, buyer.evm, st[1], int(st[2]), nonce)
            sig = pqc_sign(buyer.pqc.secret_key, lib.pqc_signing_payload(msgb))
            lib.send_evm_expect_success(w3, buyer, vault.functions.release(eid, sig), gas=8_000_000)
            seller = acct(SELLERS[n % len(SELLERS)])
            lib.send_evm_expect_success(w3, seller, vault.functions.withdrawCredits())
            print(f"settled escrow {eid}", flush=True)

        # eligible-only: attest, no release (escrow 10-13)
        for (n, lid, eid, buyer_idx) in listings_info[10:14]:
            st = vault.functions.getEscrow(eid).call()
            if int(st[5]) != 1 or bool(st[8]):
                print(f"skip eligible escrow {eid} (status={st[5]} attested={st[8]})", flush=True)
                continue
            buyer = acct(buyer_idx)
            lib.send_evm_expect_success(w3, buyer, vault.functions.confirmReceipt(eid))
            ev = w3.keccak(text=f"evidence-{eid}")
            lib.submit_pq_attestation(w3, vault, registry, verifier, eid, bytes(ev), submitter=buyer)
            print(f"eligible escrow {eid}", flush=True)

        # funded-only: escrow 14-16 left funded
        # dispute on escrow 16 (skip if already disputed)
        n, lid, eid, buyer_idx = listings_info[16]
        if int(vault.functions.getEscrow(eid).call()[5]) == 5:  # Disputed
            print(f"escrow {eid} already disputed", flush=True)
        else:
            buyer = acct(buyer_idx)
            bond = int(board.functions.disputeBondFor(int(vault.functions.getEscrow(eid).call()[2])).call())
            lib.send_evm_expect_success(w3, buyer, board.functions.openDispute(eid), value=bond)
            print(f"disputed escrow {eid} bond={bond} wei", flush=True)

        # DAO proposal: setFeeBps 200->200 (no-op value, real vote flow)
        if int(dao.functions.proposalCount().call()) > 1:
            print("DAO proposal already exists, skipping", flush=True)
            print("DONE")
            return
        vault_addr = w3.to_checksum_address(vault.address)
        from eth_abi import encode as _enc
        calldata = bytes.fromhex(w3.keccak(text="setFeeBps(uint256)").hex()[:8]) + _enc(["uint256"], [200])
        prop_desc = "Seed governance proposal: keep fee at 2%."
        tx = lib.send_evm_expect_success(w3, acct(0), dao.functions.propose(
            vault_addr, bytes.fromhex(calldata[2:].hex()) if isinstance(calldata, str) else calldata,
            "keep-fee-2pct", prop_desc, 3 * 24 * 3600), value=50_000_000_000_000_000)
        pid = None
        rc = w3.eth.get_transaction_receipt(tx["hash"])
        for raw_log in rc.logs:
            try:
                log = dao.events.ProposalCreated().process_log(raw_log)
                pid = int(log["args"]["proposalId"])
            except Exception:
                continue
        print(f"DAO proposal {pid} tx={tx['hash'][:18]}", flush=True)
        if pid is not None:
            for voter in [0, 1, 4]:
                lib.send_evm_expect_success(w3, acct(voter), dao.functions.castVote(pid, 1), value=50_000_000_000_000_000)
            print("DAO votes cast (3, stake-weighted)", flush=True)

    print("DONE")
if __name__ == "__main__":
    main()
