# Sweeft — Testnet Deployment Record

**Network:** QoreChain Diana (Cosmos chain `qorechain-diana`, EVM chain ID `9800`)
**Deployer:** `qor1etuzhk8tmpmrfmakzzhx8fau788r4jrapjkzlp` / `0xcaF82Bd8EBd87634eFb610aE63a7bCf1CE3ac87D`
**Deployed:** 19 November 2026
**Explorer:** https://explore.qore.network

## Contracts

| Contract | Address | Deploy tx |
|---|---|---|
| SweeftOracleRegistry | `0xecb16561cfdff10336b278f8107a077fe7a53c6d` | `0x3d2743b89f62ca9aa287b555c097cfae88ce40296b423ffa4fa2935c36ca9a92` |
| SweeftVault | `0x315f2f19de227bb7d01e4315085c6919e7b654c6` | `0xd2cefb2e0f4e79e6203e6ad15cfd9ba5012ea297ac508a9a7fece5a62e8a3e02` |
| SweeftMarketplace | `0x86e97fb8653588a2533d55426475cd3a1d04f030` | `0x5324704a6c0671dbda2cc0338a77aba859c39f3d1e0e912268e1e02fcde75a7e` |
| SweeftDAO | `0x03a0c71c42dcef463f8b472cb39991cedac2dc1b` | `0xeb4a1100b20be48acd41099a2f9cc9ef3b316f5e2c013db244e477a9a9f3e0c3` |

## Wiring (verified on-chain via `eth_call`)

- `SweeftVault.oracleRegistry()` = `0xecb1…3c6d` ✓
- `SweeftVault.marketplace()` = `0x86e9…f030` ✓ (set by `setMarketplace` tx `0xd82a…fdc8`)
- `SweeftMarketplace.vault()` = `0x315f…54c6` ✓
- `SweeftOracleRegistry.owner()` = `0x03a0…dc1b` ✓ — **the DAO owns the verifier registry**, so passed proposals change verifier authorization (tx `0xbb75…43d0`)

## Post-quantum integration status

| Step | Transaction | Tier |
|---|---|---|
| ML-DSA-87 key registration (`MsgRegisterPQCKeyV2`) | `F260CE20…0BDE7` | `enrollment` |
| Scoped EVM window (`MsgOpenEVMWindow`: 15,000 blocks / 200 txs / 30 QOR) | `B6C2AB7E…5D724A` | `pqc` (hybrid, 1 ML-DSA-87 layer) |
| Contract deploys (EVM lane, inside the window) | see above | `classical` — protected by the window; release/refund authorization happens inside `SweeftVault` via `pqcVerify` |

## End-to-end evidence (19 Nov 2026)

**Complete market scenario** (`tools/e2e_marketplace.py`): fund seller + verifier →
register their PQ keys → open their scoped windows → DAO approves the verifier
(propose → vote → execute, tx `0x3306B058…`) → seller lists → buyer purchases
(escrow funded atomically) → seller marks delivered → verifier attests evidence
→ inspection window passes → buyer's ML-DSA-87 signature verified on-chain by
`pqcVerify` → **seller paid 0.1 QOR**.

| Step | Transaction |
|---|---|
| Seller PQ registration | `DF0284D6…AAFC` (height 10386444) |
| Seller scoped EVM window | `B78A20AB…9A0C` (pqc_hybrid_verify event) |
| Listing #0 created | `0xf5a4823073c28046870350cc0a60377cc15486a8733a8ee4811fd8212d6f1e45` |
| Purchase → escrow #3 funded | `0xa9b9c7a883eb2d3b02f53ebd58a4f53f38abee0d8b68c14057ce0000255f674c` |
| Mark delivered | `0x40330819f59afa59ea1dcaaad1d5ef2969c5dc541ef8e1376d2e6d9104a772d6` |
| Verifier attestation | `0x9be3bce4bb160bb3eced723bc8911003a326b085af73e4bdd200f76ce9ce1f2e` |
| PQ-signed release | `0x2718991de9f16232580771084858d54f1a1078cf39d8af1b12319754a46c44d3` |

**Attack simulation** (`tools/e2e_attack.py`) — both blocked on-chain:

| Attack | Transaction | Result |
|---|---|---|
| Release signed with the wrong ML-DSA-87 key | `0xafde26a0345a35f26a9d231b289682a0069ead63465efd900f22b04394956361` | reverted, escrow untouched |
| Signature over a tampered amount | `0x10e2fb73ea43e311bb7ed67391a2a5bb7fbee7a6380788ac0c9e695526a16825` | reverted |
| Control: correct buyer signature | `0x921dd1e148016aadb08e60873d267e5f6a0bbc576fbdee4b74dd5cb3c7da5b19` | settled |

## Reproduce

```bash
# fund the deployer address from https://dashboard.qorechain.io/faucet, then:
.venv/bin/python tools/qor_account.py register   # one-time PQ key registration
.venv/bin/python tools/qor_account.py window     # open scoped EVM window
cd contracts && forge script script/Deploy.s.sol --rpc-url $QORECHAIN_EVM_RPC_URL --broadcast
```
