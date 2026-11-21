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
delegated buyer under a chain-enforced spending mandate — it never holds the
authority to move funds outside that mandate.

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
| **Sweeft Market** | On-chain listings + Django discovery/search | contracts deployed + purchase flow proven on testnet |
| **Sweeft Vault** | Escrow with PQ-gated release, 2% fee on release | deployed + release, attack and fee-split tests passing on testnet |
| **Sweeft Oracle** | Fulfilment evidence + verifier attestations | registry deployed, DAO-governed verifiers proven on-chain |
| **Sweeft Cred** | Reputation from verified outcomes only | scoring live from indexed completions |
| **Sweeft AI** | Natural-language commerce, mandate-capped autonomous buying (Meta Model API) | adapter in place, chat wiring in progress |
| **Sweeft DAO** | Proposal registry; governs verifiers, fees and dispute parameters | DAO2 deployed and owns registry, vault and board |
| **Dispute Board** | Staked resolver panels (20 QOR min, 3 members, 2-of-3) | deployed + full staked flow proven on testnet |

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
  chain ID, contract, recipient, amount and nonce — verified on-chain.
- A leaked classical (secp256k1) key alone cannot move escrowed funds.
- Escrow terms cannot be modified after funding; duplicate deposits and
  releases are rejected; state transitions are validated.
- The AI agent acts only within an owner-signed, chain-enforced spending
  mandate (QoreChain authenticators); it cannot release escrow, attest as an
  oracle, or vote in the DAO.
- AI output is never treated as authorization; the contract independently
  enforces its rules.

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
- [`docs/AUDIT.md`](docs/AUDIT.md) — QCAI audit findings and resolutions (in progress)
- [`AI_USAGE.md`](AI_USAGE.md) — how AI was used during development

## Licence

MIT — see [LICENSE](LICENSE).
