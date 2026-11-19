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

## Reproduce

```bash
# fund the deployer address from https://dashboard.qorechain.io/faucet, then:
.venv/bin/python tools/qor_account.py register   # one-time PQ key registration
.venv/bin/python tools/qor_account.py window     # open scoped EVM window
cd contracts && forge script script/Deploy.s.sol --rpc-url $QORECHAIN_EVM_RPC_URL --broadcast
```
