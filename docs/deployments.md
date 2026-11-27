# Sweeft — Testnet Deployment Record

**Network:** QoreChain Diana (Cosmos chain `qorechain-diana`, EVM chain ID `9800`)
**Deployer:** `qor1etuzhk8tmpmrfmakzzhx8fau788r4jrapjkzlp` / `0xcaF82Bd8EBd87634eFb610aE63a7bCf1CE3ac87D`
**Explorer:** https://explore.qore.network

## v9 — hardened stack (live; deployed 27 November 2026)

Built from the hardening wave (carrier domain separation, PQ verifier
attestations with relayer submissions, committed future-block seeds,
credits-only settlement, typed registry reads). Deployment is **two
scripts + one cast send**, because `addVerifier` reads the chain PQC
precompile that forge's local simulation cannot reach:

```bash
# 1. core stack (no registry registration yet)
forge script script/DeployStack.s.sol --rpc-url diana --broadcast
# 2. register the verifier (pre-pinned to keyVersion 1 = ML-DSA-87)
cast send $SWEEFT_ORACLE_REGISTRY_ADDRESS "addVerifier(address)" \
  $SWEEFT_VERIFIER_ADDRESS --rpc-url diana --private-key $DEPLOYER_PRIVATE_KEY
# 3. DAO + allowlist + ownership handover
forge script script/Handover.s.sol --rpc-url diana --broadcast
```

| Contract | Address |
|---|---|
| **SweeftOracleRegistry (v9)** | `0x35720a83daaa400ae404b20b3769d9afc56253fc` |
| **SweeftVault (v9)** | `0x21b8a243bf96340ebe5b78b296004f1bf76862ce` |
| **SweeftMarketplace (v9)** | `0x1d60eb9325a9c3da7b95f21171a2187b1480fb55` |
| **SweeftDisputeBoard (v9)** | `0x7f7c0f74f86dcc49e8373d2c140dfa5213b08001` |
| **SweeftDAO2 (v9)** | `0x428370F58AbF859672EB4516ce81cF58EcDAC91A` |

### v9 end-to-end evidence (27 November 2026)

`tools/e2e_marketplace.py` against vault `0x21b8…862ce` — full PQ-gated
release on v9 (run twice, both PASS), attesting with the verifier's
ML-DSA-87 signature via the **relayed submission** path:

| Step | Escrow #0 | Escrow #1 |
|---|---|---|
| release (ML-DSA-87 via `pqcVerify`) | `0xd24afb16…` | `0x0320db17…` |

Observed both runs: seller credited 0.098 QOR (0.1 − 2% fee), withdrew
on-chain, escrow **Completed**. Fixtures: escrow #2 (Funded), escrow #3
(release-eligible). Playwright E2E **32/32** on v9. Indexer synced
(0 handler failures).

Full release hashes (27 Nov 2026): escrow #0
`0xd24afb1680f59de25bc22a0385bbd32d98f57d5838be35863f7e7dd6149118a8`,
escrow #1 `0x0320db17d37d8f446e2d4a9ecc47c7fb885a011b8e42b2732ed95d2ec38f3617`.
DeployStack txs include Vault `0xa0680fcf…` and Registry
`0xf9c27d3e…`; Handover DAO2 deploy `0xcc92339a…` (see broadcast files
under `contracts/broadcast/`).

### Verify the deployment matches the source (27 Nov 2026)

```bash
cd contracts && forge build
# compare on-chain code length to compiled deployedBytecode length
# Registry + DAO2: byte-exact. Vault/Board/Marketplace: length-identical,
# differ only by immutable injection (oracleRegistry/treasury/deployedAt
# constructor args in DeployStack.s.sol / Handover.s.sol).
cast call $SWEEFT_VAULT_ADDRESS "owner()(address)" --rpc-url diana        # DAO2
cast call $SWEEFT_VAULT_ADDRESS "feeBps()(uint256)" --rpc-url diana      # 200
cast call $SWEEFT_ORACLE_REGISTRY_ADDRESS "keyVersion(address)(uint8)" \
  $SWEEFT_VERIFIER_ADDRESS --rpc-url diana                                # 1
cast call $SWEEFT_VAULT_ADDRESS "isCarrier(address)(bool)" \
  $SWEEFT_CARRIER_ADDRESS --rpc-url diana                                # true
# Public PQ verification of a real release:
curl "/verify/?tx=0xd24afb1680f59de25bc22a0385bbd32d98f57d5838be35863f7e7dd6149118a8"
# Attack reproduction:
.venv/bin/python tools/qday_attack_demo.py
```

## v8 — credits-only settlement (superseded by v9; 26 November 2026)

Same contracts as v7 plus the Stage 5 pattern-removal patch (credits-only
settlement, named access modifiers, typed registry calls, fee-bps bound,
absolute draw cap). Deployed with `contracts/script/DeployV6.s.sol`
(45 txs). Wiring verified on-chain via `eth_call` (all owners = DAO2,
`feeBps = 200`, `MAX_DRAW_ATTEMPTS = 128`, verifier + carrier registered,
typed-call registry live).

| Contract | Address |
|---|---|
| **SweeftOracleRegistry (v8)** | `0x76D4F6D164C688b319eE0A16003a9c06f5b1AB7A` |
| **SweeftVault (v8)** | `0x820CE1C670D26A2fF6ca5ce53f5a9EFdf3dC869a` |
| **SweeftMarketplace (v8)** | `0xf5cC7Bf4EECC160E23b4fF615E68D716bEFCd47C` |
| **SweeftDisputeBoard (v8)** | `0x50a74dD32647bcf456DcE09b76849C5EBD2A0508` |
| **SweeftDAO2 (v8)** | `0x91d0eCCE908bec0FcF06fB8d419ad9edb43Cf59b` |

### v8 end-to-end evidence (26 November 2026)

`tools/e2e_marketplace.py` against vault `0x820C…869a` — full PQ-gated
release on v8 (run twice, both PASS). Settlement is **credits-only**:
release credits the seller, the seller withdraws:

| Step | Escrow #0 | Escrow #1 |
|---|---|---|
| release (ML-DSA-87 via `pqcVerify`) | `0x123c059f…` | `0x5fb42c9d…` |
| withdrawCredits (seller) | `0xa64ed602…` | — |

Observed both runs: seller credited 0.098 QOR (0.1 − 2% fee), escrow
**Completed**, listing **Sold** (net balance delta is credited minus the
withdraw tx's gas).
Fixtures: escrow #2 (Funded), escrow #3 (release-eligible). Playwright E2E
**32/32** on v8. Indexer synced (0 handler failures).

**Audit scope note:** v8 == Stage 6 bundle source; Stage 6 QCAI (72/100)
findings fixed/documented in `docs/AUDIT.md` (Stage 6 section).

## v7 — patched v6 (superseded by v8; 25 November 2026)

Same contracts as v6 plus the Stage 4 patch (CEI ordering in
`finalize`/`_finalizeAppeal`/`DAO2.execute`, bounded `_drawPanel`,
`_feeForAmount` overflow guard). Deployed with
`contracts/script/DeployV6.s.sol` (45 txs). Wiring verified on-chain via
`eth_call` (owners, `feeBps`, `threshold`, board/marketplace wiring,
`MAX_DRAW_ATTEMPTS_PER_POOL = 6`, verifier + carrier registration).

| Contract | Address |
|---|---|
| **SweeftOracleRegistry (v7)** | `0x6926ebda01f5d0b1dDe95e9f84A4Ecf682348b8E` |
| **SweeftVault (v7)** | `0xA575cbEe7f1a51A55bF45a743AF5ECf327bBd1c6` |
| **SweeftMarketplace (v7)** | `0x721165Eb0Ed91027A1A7B4BC29E8e41930b85236` |
| **SweeftDisputeBoard (v7)** | `0x62E3d8c118855492d35829daF2201715789b39d6` |
| **SweeftDAO2 (v7)** | `0xA1235E3617738082D749AD81f0558eaB2E39ba29` |

### v7 end-to-end evidence (25 November 2026)

`tools/e2e_marketplace.py` against vault `0xA575…1c6` — full PQ-gated
release on v7 (run twice, both PASS):

| Step | Escrow #0 | Escrow #1 |
|---|---|---|
| release (ML-DSA-87 via `pqcVerify`) | `0x299fafea…` | `0x47f2cf76…` |

Observed both runs: seller received 0.098 QOR (0.1 − 2% fee), escrow
**Completed**, listing **Sold**.
Fixtures: escrow #2 (Funded), escrow #3 (release-eligible). Playwright E2E
**32/32** on v7. Indexer synced (0 handler failures).

**Audit scope note:** v7 == patched v6 source; Stage 4 QCAI (72/100) findings
are fixed/documented in `docs/AUDIT.md`, Stage 5 bundle in
`docs/audit/stage-5/` (submission pending — see below).

## v6 — hardening release (superseded by v7; 24 November 2026)

Deployed with `contracts/script/DeployV6.s.sol` after the deployer was topped
up via the faucet (100 QOR). Wiring verified on-chain via `eth_call` (owners,
`feeBps`, `threshold`, board/marketplace wiring, verifier + carrier
registration, DAO allowlist + critical self-governance).

| Contract | Address | Notes |
|---|---|---|
| **SweeftOracleRegistry (v6)** | `0x8f02e5c7A12677B8E264Ec3F1eC01a25E93E9734` | M-of-N threshold (1 on testnet); owner = DAO2 |
| **SweeftVault (v6)** | `0x3F27405766e9c820eCCC650e5b8c48D3AeE6715f` | board-only `raiseDispute`; proof-based expiry (`carrierDelivered`); per-escrow nonce |
| **SweeftMarketplace (v6)** | `0x95ee5565911dC8c99037B9654370438E78678594` | purchase pins price + metadata hash |
| **SweeftDisputeBoard (v6)** | `0xbbbED3653Fb3aAD8a4E803ab34B506DfFF4b20a5` | random staked panels (20 QOR + 100% escrow), real 5-resolver appeal, fixed bond fee |
| **SweeftDAO2 (v6)** | `0x4Db7cC7Bf39c9F1eB93D1727Bc5074284f397b2C` | stake-weighted votes (0.01 min, 0.03 quorum, 0.05 critical), guardian veto, cancel/expire; owns itself + the stack |

Verified constants: `feeBps = 200`, `MIN_VOTING_PERIOD = 3 days`,
`TIMELOCK = 2 days`, `PROPOSER_BOND = 0.05 QOR`, `minVoteStake = 0.01 QOR`,
`quorumStake = 0.03 QOR`, `criticalQuorumStake = 0.05 QOR`, board
`minStake = 20 QOR`, `joinWindow = 6h`, `votingPeriod = 48h`,
`appealWindow = 2d`, registry `threshold = 1`.
Verifier: `0x9E9745aABd5706291C0D4CA2FD2022B832a875c8`. Carrier (Demo,
`LOG-DEMO-001`): `0xd2908Fd85fc5D5141AD2Bdd3913394245236Ec41`.

### v6 end-to-end evidence (24 November 2026)

`tools/e2e_marketplace.py` against vault `0x3F27…715f` — full PQ-gated
release on v6 (run twice, both PASS):

| Step | Escrow #0 | Escrow #1 |
|---|---|---|
| createEscrow (funded atomically) | `0x12334733…` | `0x71e8cea…` |
| attestEvidence (verifier) | `0xf57a9012…` | `0xe19ca74a…` |
| confirmReceipt | `0x4ea84b2d…` | `0x5d830e94…` |
| release (ML-DSA-87 via `pqcVerify`) | `0x598b50c2…` | `0x6f11f4b2…` |

Observed both runs: seller received 0.098 QOR (0.1 − 2% fee), escrow
**Completed**, listing **Sold**; dispute reward pool holds 0.0012 QOR
(30% fee share × 2 releases). Django relayer reads confirmed against v6
(`escrow_state`, `board_state`, `isVerifier`). The indexer was synced to the
v6 tip (`sync_all`, 0 handler failures).

**Demo/E2E fixtures (24 November 2026):** escrow #2 (Funded, via
`tools/create_funded_escrow.py`) and escrow #3 (release-eligible, via
`tools/create_eligible_escrow.py`). Playwright E2E against the local app:
**32/32 checks passed** (pages, wallet sessions, role-gated escrow actions,
evidence, verifier attest, disputes, release-request for escrow #3).

**Audit scope note:** the Stage 3 QCAI audit (78/100) covers **v5 only**
(see `docs/AUDIT.md`). v6 is deployed but has not been externally audited;
its evidence is the 131-test Foundry suite plus the live release above.

## v5 — hardened stack (superseded by v6; 24 November 2026)

Deployed with `contracts/script/DeployV5.s.sol` after the external security
review (see `docs/AUDIT.md`). Wiring verified on-chain via `eth_call`
(`tools/verify_wiring_v5.py`).

| Contract | Address | Notes |
|---|---|---|
| **SweeftOracleRegistry (v5)** | `0x07712806b83fac288f2f61f892cd26f8778b94a2` | M-of-N `threshold` (1 on testnet); owner = DAO2 |
| **SweeftVault (v5)** | `0x979d3d6688600fdee7ce61e978bd8398d5e1b007` | deadline bounds, per-escrow nonce, fee snapshot, bound carrier attestation |
| **SweeftMarketplace (v5)** | `0xee9f9f0967db0fb3739cb4cd8e2e75fbf5896419` | purchase pins price + metadata hash |
| **SweeftDisputeBoard (v5)** | `0x1aa3156cb862e3569fa12dc8ab5145efb2d15fb9` | proportional stake, slashing, bond, appeal window |
| **SweeftDAO2 (v5)** | `0x23dc3d2014c62095b8b5a23c7552301cf829bdaf` | bounded periods, selector allowlist, quorum, timelock, bond; owns itself + the stack |

Verified constants: `feeBps = 200`, `MIN_VOTING_PERIOD = 3 days`,
`TIMELOCK = 2 days`, `PROPOSER_BOND = 0.05 QOR`, registry `threshold = 1`.
Verifier: `0x9E9745aABd5706291C0D4CA2FD2022B832a875c8`. Carrier (Demo, `LOG-DEMO-001`):
`0xd2908Fd85fc5D5141AD2Bdd3913394245236Ec41`.

### v5 hardening (summary — full mapping in `docs/AUDIT.md`)

- Carrier attestation is bound to `(carrier, escrow, tracking, status, nonce,
  freshness)`; only `DELIVERED` counts; the caller must be the escrow's partner.
- Delivery deadlines are bounded `[1 day, 90 days]`; buyer must hold a proven key.
- Platform fee + treasury are snapshotted per escrow at creation.
- Verifier attestation requires the registry threshold (M-of-N).
- Money paths are reentrancy-guarded with a push-with-credit fallback.
- DAO governance: `(target, selector)` allowlist, quorum, timelock, proposer bond.

### v5 end-to-end evidence (24 November 2026)

`tools/e2e_flow.py` against vault `0x979d…b007` — full PQ-gated release:

| Step | Transaction |
|---|---|
| createEscrow #1 (funded atomically) | `0x6d08013616c75a7fde269f07fe3827559d3ea3c1ae502e869742150b5c2d4bff` |
| confirmReceipt | `0xb946f50bc0791bda706b33c48ba9d61a59aa4222eb9a847f5f38162cdb27d7c2` |
| release (ML-DSA-87 verified on-chain via `pqcVerify`) | `0x25b1fa6d99fdc1e0dd7b22acbf127b8ad81dcbe7c8f165ace5df1c51ddc37570` |

Observed: seller received 49,000 uqor (50,000 − 2% fee), escrow **Completed**,
per-escrow nonce advanced to 1.

## v4 — logistics stack (19 November 2026; superseded by v5)

| Contract | Address | Notes |
|---|---|---|
| SweeftOracleRegistry (v4) | `0xecb16561cfdff10336b278f8107a077fe7a53c6d` | kept across v3/v4 |
| SweeftVault (v4) | `0x7c170ec8ab48dfa5c86ce96c9bd4d21af6d84fc9` | carrier attestation + logistics split |
| SweeftMarketplace (v4) | `0xa2075dbca3a80192e1158cba4a822bfe835c3ea6` | physical listings carry logistics allocation |
| SweeftDisputeBoard (v4) | `0x3fe1c7e2c014b4ec9c847cc35718449245eaacb1` | staked resolver panels (20 QOR min) |
| SweeftDAO2 (v4) | `0x1af66554af38e16458c0b72352517483723379db` | owned vault + board |
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
