#!/usr/bin/env python3
"""Sweeft — attack simulation against the live Vault on QoreChain Diana.

Proves the post-quantum release gate rejects unauthorized settlement, even
when the caller controls the classical key and a valid EVM window:

  Attack 1  release signed with the WRONG ML-DSA-87 key  -> must revert
  Attack 2  release signed over a TAMPERED amount        -> must revert
  Control   release signed correctly by the buyer        -> must settle

Each attack runs against its own fresh, funded escrow. The final transaction
completes the control escrow so no funds are left hanging.

Testnet only. Requires a funded buyer (deployer) with a registered PQ key
and an open EVM window.

Usage:
    .venv/bin/python tools/e2e_attack.py
"""

from __future__ import annotations

import json
import os
import sys
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
AMOUNT = 50_000  # 0.05 QOR


def _die(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def _load_vault_abi() -> list:
    artifact = REPO_ROOT / "contracts" / "out" / "SweeftVault.sol" / "SweeftVault.json"
    return json.loads(artifact.read_text())["abi"]


class AttackRunner:
    def __init__(self):
        self.w3 = Web3(Web3.HTTPProvider(EVM_RPC))
        mnemonic = os.getenv("SWEEFT_DEPLOYER_MNEMONIC", "").strip()
        self.buyer = derive_unified_account(mnemonic, index=0)
        self.seller = derive_unified_account(mnemonic, index=1)
        self.account = self.w3.eth.account.from_key(self.buyer.private_key_hex)
        self.vault = self.w3.eth.contract(
            address=self.w3.to_checksum_address(VAULT_ADDRESS), abi=_load_vault_abi()
        )

    def _send(self, fn_call, *, value: int = 0, gas: int = 1_000_000) -> dict:
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
        return {
            "hash": tx_hash.hex(),
            "status": receipt.status,
            "block": receipt.blockNumber,
            "gas_used": receipt.gasUsed,
        }

    def _fresh_escrow(self) -> int:
        escrow_id = self.vault.functions.escrowCount().call()
        deadline = self.w3.eth.get_block("latest")["timestamp"] + 86_400
        result = self._send(
            self.vault.functions.createEscrow(self.buyer.evm, self.seller.evm, deadline, AMOUNT),
            value=AMOUNT,
        )
        if result["status"] != 1:
            _die("escrow creation failed")
        self._send(self.vault.functions.confirmReceipt(escrow_id))
        return escrow_id

    def _release_message(self, escrow_id: int, amount: int, nonce: int) -> bytes:
        return abi_encode(
            ["string", "uint256", "address", "uint256", "address", "address", "uint256", "uint256"],
            [
                "sweeft-release-v1",
                CHAIN_ID,
                VAULT_ADDRESS,
                escrow_id,
                self.buyer.evm,
                self.seller.evm,
                amount,
                nonce,
            ],
        )

    def run(self) -> None:
        print(f"Buyer: {self.buyer.evm}")
        print(f"Vault: {VAULT_ADDRESS}")
        print()

        # ------------------------------------------------------------------
        print("Attack 1: release signed with the WRONG ML-DSA-87 key")
        escrow_id = self._fresh_escrow()
        nonce = self.vault.functions.pqcNonce(self.w3.to_checksum_address(self.buyer.evm)).call()
        message = self._release_message(escrow_id, AMOUNT, nonce)
        forged_signature = pqc_sign(self.seller.pqc.secret_key, message)  # seller's key, not buyer's
        result = self._send(self.vault.functions.release(escrow_id, forged_signature), gas=8_000_000)
        print(f"  escrow #{escrow_id}  tx {result['hash']}")
        print(f"  on-chain status: {result['status']} (0 = reverted)")
        if result["status"] != 0:
            _die("ATTACK SUCCEEDED — wrong-key release was accepted")
        status = self.vault.functions.getEscrow(escrow_id).call()[5]
        if status != 1:
            _die(f"escrow state changed after attack (status={status})")
        print("  BLOCKED — escrow still Funded, no funds moved ✓")
        print()

        # ------------------------------------------------------------------
        print("Attack 2: valid buyer key, TAMPERED amount in the signed message")
        escrow_id = self._fresh_escrow()
        nonce = self.vault.functions.pqcNonce(self.w3.to_checksum_address(self.buyer.evm)).call()
        tampered = self._release_message(escrow_id, AMOUNT + 1_000_000, nonce)  # claims 1 QOR more
        tampered_signature = pqc_sign(self.buyer.pqc.secret_key, tampered)
        result = self._send(self.vault.functions.release(escrow_id, tampered_signature), gas=8_000_000)
        print(f"  escrow #{escrow_id}  tx {result['hash']}")
        print(f"  on-chain status: {result['status']} (0 = reverted)")
        if result["status"] != 0:
            _die("ATTACK SUCCEEDED — tampered release was accepted")
        print("  BLOCKED — the contract builds its own message, tampering fails ✓")
        print()

        # ------------------------------------------------------------------
        print("Control: correct buyer signature settles the escrow")
        nonce = self.vault.functions.pqcNonce(self.w3.to_checksum_address(self.buyer.evm)).call()
        message = self._release_message(escrow_id, AMOUNT, nonce)
        signature = pqc_sign(self.buyer.pqc.secret_key, message)
        result = self._send(self.vault.functions.release(escrow_id, signature), gas=8_000_000)
        print(f"  escrow #{escrow_id}  tx {result['hash']}")
        print(f"  on-chain status: {result['status']} (1 = success)")
        if result["status"] != 1:
            _die("control release failed")
        status = self.vault.functions.getEscrow(escrow_id).call()[5]
        if status != 2:
            _die(f"escrow not completed (status={status})")
        print("  SETTLED — seller paid ✓")
        print()
        print("=" * 64)
        print("ATTACK SIMULATION: 2/2 attacks blocked, control settled")


if __name__ == "__main__":
    AttackRunner().run()
