# Sweeft

**Decentralized commerce and trust ecosystem on QoreChain.**

Sweeft is a post-quantum escrow marketplace built on QoreChain. Buyers and
sellers discover each other in Django, agree terms, and settle through a
Solidity Vault deployed on the Diana testnet — where releasing funds requires
the buyer's ML-DSA-87 signature, verified on-chain by QoreChain's `pqcVerify`
precompile. Fulfilment is attested by authorized oracle verifiers, reputation
comes only from verified outcomes, and a DAO governs who may attest.

> Built for **Build Before Q-Day** (QoreChain Developer Fest) — Post-Quantum dApp category.
> Testnet only. Test tokens have no value.

## Architecture

**Django coordinates the application. Smart contracts enforce financial rules.
QoreChain provides the blockchain infrastructure.** AI assists and can act as a
delegated buyer under a bounded mandate — Django enforces per-transaction and
rolling daily caps in code, and the on-chain spending rule remains the hard cap.
The agent never holds the authority to move funds outside that mandate.

```
Browser / QoreX            Django (modular monolith)           QoreChain Diana
──────────────             ─────────────────────────           ───────────────
Marketplace UI   ────────▶ apps/marketplace (indexer view)
Escrow detail    ────────▶ apps/escrow   (lifecycle mirror)
Oracle dashboard ────────▶ apps/oracle   (evidence + attest)
AI assistant     ────────▶ apps/ai       (draft/execute w/ mandate)
                           integrations/qorechain ──────────▶ SweeftMarketplace.sol
                                                              SweeftVault.sol
                                                              SweeftOracleRegistry.sol
                                                              SweeftDAO.sol
```

- **On-chain source of truth**: listings, prices, purchase state, escrow state,
  fulfilment attestations, verifier registry, DAO proposals.
- **Off-chain**: listing metadata (hash-anchored on-chain), evidence documents,
  search index, notifications, AI conversations.

## Components

| Component | Purpose | Status |
|---|---|---|
| **Sweeft Market** | On-chain listings + Django discovery/search | v5: listings pin price + metadata hash at purchase; seller fees re-checked on price updates |
| **Sweeft Vault** | Escrow with PQ-gated release, 2% fee on release, carrier attestation | v5: deadline bounds, per-escrow nonce, fee/treasury snapshots, M-of-N verifier threshold, pull-payment fallback |
| **Sweeft Oracle** | Fulfilment evidence + verifier attestations | DAO-governed verifiers with a configurable M-of-N threshold |
| **Sweeft Cred** | Reputation from verified outcomes only | scoring live from indexed completions |
| **Sweeft AI** | Natural-language commerce, mandate-capped autonomous buying (Meta Model API) | chat wired; mandate enforced in code (per-tx + daily); Autopilot proven on testnet; negotiation against listing floors |
| **Sweeft DAO** | Proposal registry; governs verifiers, fees and dispute parameters | DAO2: bounded voting periods, (target,selector) allowlist, quorum, timelock, proposer bond; owns registry/vault/board |
| **Dispute Board** | Staked resolver panels (proportional stake, 3 members, 2-of-3) | v5: stake scales with escrow, minority/non-voter slashing, raiser bond, appeal window, deterministic expiry |
| **Logistics** | Verified physical delivery (carrier ML-DSA signatures on-chain) + digital goods | carrier attestation bound to (escrow, carrier, status, nonce); DELIVERED-only fulfilment; Demo Carrier is simulated |

## Quick start (development)

```bash
# 1. Environment
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in values

# 2. Database
createdb sweeft        # or use docker compose

# 3. Django
python manage.py migrate
python manage.py runserver
```

### Contracts (Foundry)

```bash
cd contracts
forge build
forge test
```

## QoreChain testnet (Diana)

| | |
|---|---|
| Chain ID | `qorechain-diana` (EVM `9800`) |
| REST | `https://api-testnet.qore.host` |
| RPC | `https://rpc-testnet.qore.host` |
| EVM RPC | `https://evm-testnet.qore.host` |
| Explorer | `https://explore.qore.network` |
| Faucet | `https://dashboard.qorechain.io/faucet` |

PQC precompiles (testnet): `pqcVerify` at `0x…0a01`, `pqcKeyStatus` at `0x…0a02`.

## Security model

- Only the buyer can fund their escrow; only stored roles may act.
- Release requires the buyer's ML-DSA-87 signature over a message binding
  chain ID, contract, recipient, amount and a per-escrow nonce — verified
  on-chain by `pqcVerify`.
- A leaked classical (secp256k1) key alone cannot move escrowed funds.
- **Escrow terms are frozen at funding**: the platform fee and treasury are
  snapshotted into the escrow at creation, so a later DAO change cannot alter an
  in-flight deal. Duplicate deposits and releases are rejected.
- **Bounded delivery windows**: creation rejects deadlines outside
  `[1 day, 90 days]`, so a buyer cannot set a past deadline to refund instantly.
- **Carrier attestation is bound** to `(carrier, escrow, tracking, status,
  nonce, freshness)` and only `DELIVERED` counts as fulfilment; any other status
  leaves the buyer's refund path open.
- **M-of-N verifier threshold**: one verifier can never, alone, mark an escrow
  attested and block the buyer's refund.
- **Pull-with-fallback payouts**: if a recipient rejects a transfer, the funds
  are credited for later withdrawal instead of bricking settlement; money paths
  are reentrancy-guarded.
- **Governance is hard to capture**: DAO proposals need an allowlisted
  `(target, selector)`, a 3-day minimum voting period, quorum, a 2-day timelock
  and a proposer bond; the DAO owns the registry, vault and board.
- **Disputes cost something**: resolvers stake proportionally to the escrow,
  minority/non-voters are slashed, raisers post a bond, and expiry resolves by a
  deterministic rule rather than owner discretion.
- The AI agent acts only within an owner-granted mandate: Django enforces
  per-transaction and rolling daily caps **in code** (and refuses to spend with
  no active mandate), while the on-chain spending rule is the hard cap. The
  agent cannot release escrow, attest as an oracle, or vote in the DAO.
- AI output is never treated as authorization; the contract independently
  enforces its rules. Retrieved listing text is treated as untrusted data.

See `docs/AUDIT.md` for the finding-by-finding mapping (including the external
review response) and `contracts/test/` for the regression suites.

## Wallets — QoreX and EVM wallets, and why both

Sweeft uses each wallet for what it can actually do (matching QoreX's own
documentation):

| Capability | QoreX (native lane) | MetaMask-style EVM wallets |
|---|---|---|
| Post-quantum login (ML-DSA-87 challenge, verified against the key registered on chain) | ✅ | — |
| **Escrow release signature** (`signArbitrary` → `pqcVerify` on-chain) | ✅ | — |
| Buy / raise disputes / vote / claim (EVM-lane transactions) | ⛔ (QoreX EVM lane answers account queries only, per its docs) | ✅ |
| Open scoped EVM windows, register PQ keys | ✅ (also via the QoreChain Dashboard) | — |

The post-quantum-critical steps are deliberately QoreX-only: only the wallet
holds the ML-DSA-87 key, so the release authorization cannot be produced
anywhere else. EVM actions use the strongest available EVM signer because
QoreX's EVM lane cannot sign yet — a QoreX limitation, not an integration
gap, and the split is visible in the app's connect dialog.

QoreX must be set to **Testnet (Diana)** for signing: mobile app →
Settings → "Use testnet (developers)". QoreX never switches networks on a
request's behalf.

## Documentation

- [`docs/implementation-blueprint.md`](docs/implementation-blueprint.md) — original implementation blueprint
- [`docs/AUDIT.md`](docs/AUDIT.md) — QCAI audit (Stage 1 & 2) plus the response to the external security review (v5 hardening, finding by finding)
- [`docs/proofs/`](docs/proofs/) — live testnet transaction inventory and the keeper attack log
- [`AI_USAGE.md`](AI_USAGE.md) — how AI was used during development

## Licence

MIT — see [LICENSE](LICENSE).
