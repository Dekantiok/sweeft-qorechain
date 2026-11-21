#!/usr/bin/env python3
"""Sweeft — QoreChain testnet account utility.

Manages the throwaway testnet accounts the project deploys with (deployer) and
relays agent actions from (relayer). Testnet only — never use with mainnet funds.

Commands:
    new        Generate a fresh 24-word mnemonic, derive the unified account
               (qor1 / 0x / SVM forms), print it, and store it in .env.
    show       Show the derived addresses for the stored mnemonic.
    status     Read the account's ML-DSA-87 key state and EVM window from chain.
    register   Register the account's ML-DSA-87 key (one-time; classical-
               signed, bootstrap-exempt). Requires a funded account.
    window     Open a scoped EVM authorization window (hybrid-signed).
    close      Close the EVM window immediately.
    faucet     Print the faucet URL with the account address ready to paste.

Examples:
    .venv/bin/python tools/qor_account.py new
    .venv/bin/python tools/qor_account.py status
    .venv/bin/python tools/qor_account.py register
    .venv/bin/python tools/qor_account.py window --blocks 10000 --max-txs 150
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = REPO_ROOT / ".env"
load_dotenv(ENV_FILE)

from qorsdk import (  # noqa: E402
    build_register_pqc_key,
    broadcast,
    derive_unified_account,
    fetch_pqc_status,
    generate_mnemonic,
    msg,
    sign_proof_of_possession,
)
from qorsdk.sign_eth import sign_classical_eth, sign_hybrid_eth  # noqa: E402
from qorsdk.tx import hybrid_sign_and_broadcast  # noqa: E402

REST_URL = os.getenv("QORECHAIN_REST_URL", "https://api-testnet.qore.host")
CHAIN_ID = os.getenv("QORECHAIN_CHAIN_ID", "qorechain-diana")
ENV_KEY = "SWEEFT_DEPLOYER_MNEMONIC"
FAUCET_URL = "https://dashboard.qorechain.io/faucet"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _die(message: str, code: int = 1) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def _load_account(index: int = 0):
    mnemonic = os.getenv(ENV_KEY, "").strip()
    if not mnemonic:
        _die(f"{ENV_KEY} is not set in .env — run: python tools/qor_account.py new")
    return derive_unified_account(mnemonic, index=index)


def _save_mnemonic(mnemonic: str) -> None:
    lines: list[str] = []
    if ENV_FILE.exists():
        lines = ENV_FILE.read_text().splitlines()
    lines = [line for line in lines if not line.startswith(f"{ENV_KEY}=")]
    # Quote the value: the phrase contains spaces and must survive `source`.
    lines.append(f'{ENV_KEY}="{mnemonic}"')
    ENV_FILE.write_text("\n".join(lines) + "\n")


def _fee(gas: int, gas_price_uqor: str = "0.1") -> dict:
    amount = int(float(gas_price_uqor) * gas)
    return {"amount": [{"denom": "uqor", "amount": str(amount)}], "gas": str(gas)}


def _account_info(address: str) -> dict | None:
    """Fetch account_number/sequence, or None when the account does not exist yet."""
    url = f"{REST_URL}/cosmos/auth/v1beta1/accounts/{address}"
    response = httpx.get(url, timeout=20)
    if response.status_code == 404:
        return None
    response.raise_for_status()
    account = response.json()["account"]
    base = account.get("base_account", account)
    return {
        "account_number": int(base["account_number"]),
        "sequence": int(base["sequence"]),
    }


def _print_addresses(unified) -> None:
    print(f"  qor1 (native lane):  {unified.cosmos}")
    print(f"  0x   (EVM lane):     {unified.evm}")
    print(f"  SVM  (base58):       {unified.svm}")


def _print_tx(response) -> None:
    tx_response = response.get("tx_response", response) if isinstance(response, dict) else {}
    tx_hash = tx_response.get("txhash", "?")
    code = tx_response.get("code", "?")
    print(f"  tx hash: {tx_hash}")
    print(f"  code:    {code} (0 = accepted into mempool)")
    print(f"  explorer: {os.getenv('QORECHAIN_EXPLORER_URL', 'https://explore.qore.network')} — search {tx_hash}")


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def cmd_new(args) -> None:
    mnemonic = generate_mnemonic(strength=256)
    unified = derive_unified_account(mnemonic)
    _save_mnemonic(mnemonic)

    print("Fresh testnet account generated (24 words stored in .env).")
    print()
    _print_addresses(unified)
    print()
    print("Next steps:")
    print(f"  1. Fund it: open {FAUCET_URL}")
    print(f"     Paste the qor1 address above (wait ~30s after claiming).")
    print(f"  2. Register the PQ key:  .venv/bin/python tools/qor_account.py register")
    print(f"  3. Open an EVM window:   .venv/bin/python tools/qor_account.py window")


def cmd_show(args) -> None:
    unified = _load_account(getattr(args, "index", 0))
    print("Stored testnet account:")
    _print_addresses(unified)


def cmd_faucet(args) -> None:
    unified = _load_account(getattr(args, "index", 0))
    print(f"Faucet:  {FAUCET_URL}")
    print(f"Address: {unified.cosmos}")


def cmd_status(args) -> None:
    unified = _load_account(getattr(args, "index", 0))
    print(f"Account: {unified.cosmos}")
    print()

    status = fetch_pqc_status(REST_URL, unified.cosmos)
    registered = status.get("registered")
    print(f"PQC key registered: {registered}")
    if registered:
        account = status.get("account", {})
        print(f"  algorithm:         {account.get('algorithm_name')}")
        print(f"  key type:          {account.get('key_type')}")
        print(f"  possession proven: {account.get('possession_proven')}")

    window = httpx.get(f"{REST_URL}/qorechain/pqc/v1/evm_window/{unified.cosmos}", timeout=20)
    if window.status_code == 200:
        payload = window.json()
        print(f"EVM window found:   {payload.get('found')}")
        if payload.get("found"):
            print(f"  live:            {payload.get('live')}")
            print(f"  expiry height:   {payload.get('expiry_height')}")
            print(f"  txs remaining:   {payload.get('remaining_txs')}")
            print(f"  value remaining: {payload.get('remaining_value_uqor')} uqor")
    else:
        print(f"EVM window query: HTTP {window.status_code}")

    info = _account_info(unified.cosmos)
    if info:
        print(f"account_number: {info['account_number']}  sequence: {info['sequence']}")
    else:
        print("account not funded yet — claim from the faucet first")


def cmd_register(args) -> None:
    unified = _load_account(getattr(args, "index", 0))

    status = fetch_pqc_status(REST_URL, unified.cosmos)
    if status.get("registered"):
        print("PQC key already registered for this account. Nothing to do.")
        return

    info = _account_info(unified.cosmos)
    if info is None:
        _die("account has no funds on chain yet — claim from the faucet first")

    proof = sign_proof_of_possession(chain_id=CHAIN_ID, account=unified.cosmos, keypair=unified.pqc)
    register = build_register_pqc_key(
        sender=unified.cosmos,
        dilithium_pubkey=unified.pqc.public_key,
        ecdsa_pubkey=unified.public_key,
        key_type="hybrid",
        proof_of_possession=proof,
    )

    built = sign_classical_eth(
        account=unified,
        chain_id=CHAIN_ID,
        account_number=info["account_number"],
        messages=[register],
        fee=_fee(args.gas),
        sequence=info["sequence"],
    )

    print("Registering ML-DSA-87 key (one-time, classical-signed bootstrap)...")
    response = broadcast(REST_URL, built.tx_raw_bytes)
    _print_tx(response)
    print()
    print("Next: .venv/bin/python tools/qor_account.py window")


def cmd_window(args) -> None:
    unified = _load_account(getattr(args, "index", 0))

    status = fetch_pqc_status(REST_URL, unified.cosmos)
    if not status.get("registered"):
        _die("PQC key not registered yet — run: python tools/qor_account.py register")

    info = _account_info(unified.cosmos)
    if info is None:
        _die("account not found on chain")

    open_msg = msg.pqc.open_evm_window(
        sender=unified.cosmos,
        blocks=args.blocks,
        max_txs=args.max_txs,
        max_value=str(args.max_value),
    )

    fee = _fee(args.gas)

    def build(version):
        return sign_hybrid_eth(
            account=unified,
            chain_id=CHAIN_ID,
            account_number=info["account_number"],
            messages=[open_msg],
            fee=fee,
            sequence=info["sequence"],
            sign_bytes_version=version,
        )

    print(f"Opening scoped EVM window: {args.blocks} blocks, "
          f"{args.max_txs} txs, {int(args.max_value) / 1_000_000:.2f} QOR value cap...")
    response = hybrid_sign_and_broadcast(build, chain_id=CHAIN_ID, rest_url=REST_URL)
    _print_tx(response)


def cmd_close(args) -> None:
    unified = _load_account(getattr(args, "index", 0))
    info = _account_info(unified.cosmos)
    if info is None:
        _die("account not found on chain")

    close_msg = msg.pqc.close_evm_window(sender=unified.cosmos)
    fee = _fee(args.gas)

    def build(version):
        return sign_hybrid_eth(
            account=unified,
            chain_id=CHAIN_ID,
            account_number=info["account_number"],
            messages=[close_msg],
            fee=fee,
            sequence=info["sequence"],
            sign_bytes_version=version,
        )

    response = hybrid_sign_and_broadcast(build, chain_id=CHAIN_ID, rest_url=REST_URL)
    print("EVM window closed.")
    _print_tx(response)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("new", help="generate a fresh mnemonic and store it in .env")

    show = sub.add_parser("show", help="show derived addresses for the stored mnemonic")
    show.add_argument("--index", type=int, default=0, help="mnemonic account index (0 = deployer)")

    faucet = sub.add_parser("faucet", help="print the faucet URL with the account address")
    faucet.add_argument("--index", type=int, default=0, help="mnemonic account index (0 = deployer)")

    status = sub.add_parser("status", help="read PQC key and EVM window state from chain")
    status.add_argument("--index", type=int, default=0, help="mnemonic account index (0 = deployer)")

    register = sub.add_parser("register", help="register the ML-DSA-87 key (one-time)")
    register.add_argument("--index", type=int, default=0, help="mnemonic account index (0 = deployer)")
    register.add_argument("--gas", type=int, default=600_000)

    window = sub.add_parser("window", help="open a scoped EVM authorization window")
    window.add_argument("--index", type=int, default=0, help="mnemonic account index (0 = deployer)")
    window.add_argument("--blocks", type=int, default=10_000, help="window length in blocks (max 17280)")
    window.add_argument("--max-txs", type=int, default=150, help="max EVM txs in the window (max 1000)")
    window.add_argument("--max-value", type=int, default=20_000_000, help="value cap in uqor (default 20 QOR)")
    window.add_argument("--gas", type=int, default=500_000)

    close = sub.add_parser("close", help="close the EVM window now")
    close.add_argument("--index", type=int, default=0, help="mnemonic account index (0 = deployer)")
    close.add_argument("--gas", type=int, default=400_000)

    args = parser.parse_args()
    handlers = {
        "new": cmd_new,
        "show": cmd_show,
        "faucet": cmd_faucet,
        "status": cmd_status,
        "register": cmd_register,
        "window": cmd_window,
        "close": cmd_close,
    }
    handlers[args.command](args)


if __name__ == "__main__":
    main()
