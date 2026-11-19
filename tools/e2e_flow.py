#!/usr/bin/env python3
"""Sweeft — end-to-end money path test on QoreChain Diana.

Exercises the full escrow settlement on the live testnet:
  1. Buyer creates an escrow on SweeftVault (funded atomically)
  2. Buyer confirms receipt
  3. Buyer signs the release message with their ML-DSA-87 key
  4. Anyone submits the release; the Vault verifies the signature on-chain
     via pqcVerify and pays the seller
  5. Script asserts the seller was paid and the escrow is Completed

Buyer = the deployer account (index 0 of the stored mnemonic)
Seller = index 1 of the same mnemonic (never needs to act in this path)

Requires: a funded buyer with a registered PQ key and an open EVM window.
Testnet only.

Usage:
    .venv/bin/python tools/e2e_flow.py
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from dotenv import load_dotenv

REPO_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(REPO_ROOT / ".env")
sys.path.insert(0, str(REPO_ROOT))

from eth_abi import encode as abi_encode  # noqa: E402
from qorsdk import derive_unified_account, pqc_sign  # noqa: E402
from web3 import Web3  # noqa: E402

EVM_RPC = os.getenv("QORECHAIN_EVM_RPC_URL", "https://evm-testnet.qore.host")
EXPLORER = os.getenv("QORECHAIN_EXPLORER_URL", "https://explore.qore.network")
CHAIN_ID = int(os.getenv("QORECHAIN_EVM_CHAIN_ID", "9800"))
VAULT_ADDRESS = os.getenv("SWEEFT_VAULT_ADDRESS", "")
AMOUNT = 50_000  # 0.05 QOR in uqor — small testnet amount


def _die(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def _load_vault_abi() -> list:
    artifact = REPO_ROOT / "contracts" / "out" / "SweeftVault.sol" / "SweeftVault.json"
    if not artifact.exists():
        _die(f"ABI not found at {artifact} — run `forge build` in contracts/ first")
    return json.loads(artifact.read_text())["abi"]


class Runner:
    def __init__(self):
        self.w3 = Web3(Web3.HTTPProvider(EVM_RPC))
        if not self.w3.is_connected():
            _die(f"cannot reach {EVM_RPC}")
        if not VAULT_ADDRESS:
            _die("SWEEFT_VAULT_ADDRESS missing in .env")

        mnemonic = os.getenv("SWEEFT_DEPLOYER_MNEMONIC", "").strip()
        if not mnemonic:
            _die("SWEEFT_DEPLOYER_MNEMONIC missing in .env")

        self.buyer = derive_unified_account(mnemonic, index=0)
        self.seller = derive_unified_account(mnemonic, index=1)
        self.account = self.w3.eth.account.from_key(self.buyer.private_key_hex)
        self.vault = self.w3.eth.contract(
            address=self.w3.to_checksum_address(VAULT_ADDRESS), abi=_load_vault_abi()
        )
        self.results: dict = {}

    # -- tx helpers ---------------------------------------------------------

    def _send(self, fn_call, *, value: int = 0, gas: int = 600_000) -> dict:
        tx = fn_call.build_transaction(
            {
                "from": self.account.address,
                "value": value,
                "gas": gas,
                "gasPrice": self.w3.eth.gas_price,
                "nonce": self.w3.eth.get_transaction_count(self.account.address, "pending"),
                "chainId": CHAIN_ID,
            }
        )
        signed = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed.rawTransaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        if receipt.status != 1:
            _die(f"transaction reverted: {tx_hash.hex()} — {EXPLORER}/tx/{tx_hash.hex()}")
        return {"hash": tx_hash.hex(), "block": receipt.blockNumber, "gas_used": receipt.gasUsed}

    def _wait_balance(self, address: str, want_delta: int, before: int, tries: int = 10) -> int:
        for _ in range(tries):
            now = self.w3.eth.get_balance(self.w3.to_checksum_address(address))
            if now - before >= want_delta:
                return now
            time.sleep(3)
        return self.w3.eth.get_balance(self.w3.to_checksum_address(address))

    # -- steps --------------------------------------------------------------

    def run(self):
        print(f"Buyer : {self.buyer.evm}")
        print(f"Seller: {self.seller.evm}")
        print(f"Vault : {VAULT_ADDRESS}")
        print()

        escrow_id = self.vault.functions.escrowCount().call()
        deadline = self.w3.eth.get_block("latest")["timestamp"] + 86_400
        print(f"[1/4] createEscrow id={escrow_id} amount={AMOUNT} uqor (funded atomically)")
        result = self._send(
            self.vault.functions.createEscrow(
                self.buyer.evm, self.seller.evm, deadline, AMOUNT
            ),
            value=AMOUNT,
        )
        self.results["create"] = result
        print(f"      tx {result['hash']}")

        escrow = self.vault.functions.getEscrow(escrow_id).call()
        if escrow[5] != 1:  # status: 0=None, 1=Funded
            _die(f"escrow not funded after create (status={escrow[5]})")
        print("      escrow status = Funded (1) ✓")

        print("[2/4] confirmReceipt")
        result = self._send(self.vault.functions.confirmReceipt(escrow_id))
        self.results["confirm"] = result
        print(f"      tx {result['hash']}")

        print("[3/4] buyer signs the release message with ML-DSA-87")
        nonce = self.vault.functions.pqcNonce(self.w3.to_checksum_address(self.buyer.evm)).call()
        message = abi_encode(
            ["string", "uint256", "address", "uint256", "address", "address", "uint256", "uint256"],
            [
                "sweeft-release-v1",
                CHAIN_ID,
                VAULT_ADDRESS,
                escrow_id,
                self.buyer.evm,
                self.seller.evm,
                AMOUNT,
                nonce,
            ],
        )
        signature = pqc_sign(self.buyer.pqc.secret_key, message)
        print(f"      nonce={nonce} message={len(message)}B signature={len(signature)}B")

        print("[4/4] release(escrowId, signature) — precompile verifies on-chain")
        seller_before = self.w3.eth.get_balance(self.w3.to_checksum_address(self.seller.evm))
        result = self._send(
            self.vault.functions.release(escrow_id, signature), gas=8_000_000
        )
        self.results["release"] = result
        print(f"      tx {result['hash']}")

        seller_after = self._wait_balance(self.seller.evm, AMOUNT, seller_before)
        delta = seller_after - seller_before
        escrow = self.vault.functions.getEscrow(escrow_id).call()
        status = escrow[5]

        print()
        print("=" * 64)
        print(f"seller received : {delta} uqor ({delta / 1_000_000:.6f} QOR)")
        print(f"escrow status   : {status} (2 = Completed)")
        print(f"nonce after     : {self.vault.functions.pqcNonce(self.w3.to_checksum_address(self.buyer.evm)).call()}")
        for name in ("create", "confirm", "release"):
            print(f"{name:7s} tx      : {self.results[name]['hash']}")

        if status != 2 or delta != AMOUNT:
            _die("final assertions failed")
        print()
        print("END-TO-END PQ RELEASE: PASS")


if __name__ == "__main__":
    Runner().run()
