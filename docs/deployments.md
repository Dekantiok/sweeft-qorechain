# Sweeft — Testnet Deployment Record

**Network:** QoreChain Diana (Cosmos chain `qorechain-diana`, EVM chain ID `9800`)
**Deployer:** `qor1etuzhk8tmpmrfmakzzhx8fau788r4jrapjkzlp` / `0xcaF82Bd8EBd87634eFb610aE63a7bCf1CE3ac87D`
**Deployed:** 19 November 2026
**Explorer:** https://explore.qore.network

## Contracts

| Contract | Address | Notes |
|---|---|---|
| SweeftOracleRegistry | `0xecb16561cfdff10336b278f8107a077fe7a53c6d` | kept across v3/v4; ownership in DAO2 |
| **SweeftVault (v4)** | `0x7c170ec8ab48dfa5c86ce96c9bd4d21af6d84fc9` | adds carrier attestation + logistics split |
| **SweeftMarketplace (v4)** | `0xa2075dbca3a80192e1158cba4a822bfe835c3ea6` | physical listings carry logistics allocation |
| **SweeftDisputeBoard** | `0x3fe1c7e2c014b4ec9c847cc35718449245eaacb1` | staked resolver panels (20 QOR min) |
| **SweeftDAO2** | `0x1af66554af38e16458c0b72352517483723379db` | owns vault + board; allowlisted targets |
| SweeftDAO (v1) | `0x03a0c71c42dcef463f8b472cb39991cedac2dc1b` | executed the registry migration |

### v4 additions (logistics — Phase 2)

- Vault `attestCarrierEvidence`: verifies the carrier's ML-DSA-87 signature over
  `sweeft-carrier-v1|provider|tracking|escrow|status|events` **on-chain** via
  `pqcVerify` — the TEE is replaced by post-quantum verification on QoreChain.
- Vault `createEscrowWithLogistics`: three-way split at release — goods to
  seller (minus 2% fee to treasury/dispute), logistics share to the carrier.
- Marketplace `createListingWithLogistics` for physical goods; digital = no carrier.
- Demo Carrier: `LOG-DEMO-001`, `0xd2908Fd85fc5D5141AD2Bdd3913394245236Ec41`
  (mnemonic index 6), registered via a DAO2 proposal.

### v3 economics

- Platform fee: **2% on release only** — refunds are free.
- Split: **70% DAO treasury / 30% dispute reward pool**.
- Resolvers: **20 QOR minimum stake**, up to 3 per dispute, 2-of-3 majority,
  each voter claims **10% of the escrow fee** from the pool.

## Governance migration evidence

| Step | Result |
|---|---|
| DAO v1 proposal "Migrate verifier governance to DAO v2" | executed — tx `0x4e84b6a65ccbbdfd4a85d202c5e6d25f4fb6a5dbd08617c2d0a201526dab14cd` |
| Registry owner after execution | `0x794b2Aa6b5B7884eC71cF0361A41A6d711B0996a` (DAO2) |

## Dispute resolution evidence (Diana testnet)

Full staked-resolver flow (`tools/e2e_dispute.py`): resolvers stake 20 QOR →
buyer freezes an escrow with a dispute → three resolvers join → 2-of-3 vote
release → seller paid minus the 2% fee → voters claim rewards from the pool.

| Step | Observed |
|---|---|
| Seller received | 0.098 QOR on a 0.1 QOR escrow (fee 0.002) |
| Treasury share | 0.0014 QOR (70%) |
| Dispute pool share | 0.0006 QOR (30%) |
| Resolver reward each | 0.0002 QOR (10% of fee) |
| Escrow final state | Completed (release) / Refunded (refund path) |

## Release authorization format (QoreSign-compatible)

The buyer's ML-DSA-87 signature covers exactly what QoreX's `signArbitrary` produces
(message-signing-v1):

```
ML-DSA-87.Sign(sk, "qorechain-msg-v1|" + chain_id + "|" + data)
```

where `data` is the human-readable release message the buyer sees in the wallet:

```
sweeft-release-v1|vault=0x…|escrow=…|buyer=0x…|recipient=0x…|amount=…|nonce=…
```

The contract rebuilds these exact bytes and verifies them with `pqcVerify`.
Format compatibility is proven against the official QoreSign test vectors
(`qoresign-v1.json`): sign-bytes and ML-DSA-87 signatures match bit-for-bit,
and the full flow passes on-chain (below).

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
