# Sweeft

**Decentralized commerce and trust ecosystem on QoreChain.**

Sweeft is a post-quantum commerce ecosystem on QoreChain. Buyers and
sellers discover each other in Django, agree terms, and settle through a
Solidity Vault deployed on the Diana testnet — where releasing funds requires
the buyer's ML-DSA-87 signature, verified on-chain by QoreChain's `pqcVerify`
precompile. Escrow is one component: the marketplace, oracle verifiers,
dispute board, DAO and AI assistant are the rest, and reputation comes only
from verified outcomes.

> Built for **Build Before Q-Day** (QoreChain Developer Fest) — Post-Quantum dApp category.
> Testnet only. Test tokens have no value.

## Deployment status

- **Live on Diana: v8** — deployed 26 November 2026 (`docs/deployments.md`:
  Vault `0x820C…869a`, DAO2 `0x91d0…ad9edb43Cf59b`) — credits-only
  settlement + Stage 5/6 pattern removal. Two verified PQ releases
  (credited 0.098 of 0.1 QOR after the 2% fee, escrow Completed, seller
  withdrew on-chain). `.env` and the hosted demo point at v8.
- **Superseded: v7/v6/v5** — previous live stacks (v7: push settlement;
  v6/v5 buy-side identical until the credits-only change).
- **Audit scope:** Stage 3 (78/100) covers v5; Stage 4 (72/100) covers v6;
  v7 == patched v6 source (Stage 5 bundle in `docs/audit/stage-5/`); v8 ==
  Stage 6 bundle source (`docs/audit/stage-6/`), live since 26 Nov 2026.

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
                                                              SweeftDAO2.sol
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
| **Sweeft DAO** | Proposal registry; governs verifiers, fees and dispute parameters | v6 live: stake-weighted votes (QOR escrowed per vote, locked until final), bounded voting periods, (target,selector) allowlist, stake quorum (0.03 QOR, 0.05 critical for self-governance), 2-day timelock, proposer bond, guardian veto during the timelock, cancel/expire; owns registry/vault/board |
| **Dispute Board** | Staked resolver panels | v6 live: random panel drawn from the staked pool (20 QOR + 100% of escrow), non-voter slashing, raiser bond, fixed resolver fee from the bond for either outcome, real appeal to a 5-resolver panel (3-of-5) that can overturn and slash the first panel, proof-based permissionless expiry |
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
  and a proposer bond; the DAO owns the registry, vault and board. In v6, votes
  are stake-weighted (QOR escrowed with the vote and locked until the proposal
  is final), self-governance calls need a higher stake quorum, and a guardian
  may veto during the timelock.
- **Disputes cost something**: resolvers stake proportionally to the escrow,
  non-voters are slashed, raisers post a bond, and expiry resolves by a
  deterministic rule rather than owner discretion. In v6 the panel is drawn
  randomly from the staked pool, resolvers are paid a fixed fee from the bond
  for either outcome, and either party can appeal the first decision to a
  larger panel (a successful appeal slashes the first panel).
- The AI agent acts only within an owner-granted mandate: Django enforces
  per-transaction and rolling daily caps **in code** (and refuses to spend with
  no active mandate), while the on-chain spending rule is the hard cap. The
  agent cannot release escrow, attest as an oracle, or vote in the DAO.
- AI output is never treated as authorization; the contract independently
  enforces its rules. Retrieved listing text is treated as untrusted data.

See `docs/AUDIT.md` for the finding-by-finding mapping (including the external
review response and the v6 hardening notes) and `contracts/test/` for the
regression suites (131 Foundry + 28 Django tests at the time of writing).

### Known limitations

- `SweeftVault.setDisputeBoard` / `setMarketplace` are one-shot and callable
  only by the deployer — after deployment the DAO cannot rewire those two
  addresses. They are wired once at deploy time in `DeployV6.s.sol`.
- Dispute panel randomness uses `block.prevrandao` (testnet-grade; a validator
  can bias it). A commit-reveal or VRF source is future work.
- The Demo Carrier is simulated; real carriers sign with their own keys
  (`docs/AUDIT.md` B-10).

## Public API (v1)

Read-only JSON for every component — no auth, rate-limited (5s per IP per
endpoint), indexed data only (chain reads are cached):

```bash
curl /api/v1/                       # component + contract index
curl /api/v1/listings/?status=active
curl /api/v1/listings/0/
curl /api/v1/escrows/?seller=0x…&state=funded
curl /api/v1/escrows/3/              # includes live state + proof link
curl /api/v1/disputes/?state=final
curl /api/v1/proposals/
curl /api/v1/board/                  # live pool, windows, stake minimums
curl /api/v1/verifiers/              # verifiers with attested evidence
```

Units are explicit per field (`uqor` native, `wei` EVM lane). Writes stay in
the wallet UI. Full contract addresses are in the index response.

## Integration paths for other builders

Beyond the REST API, Sweeft's components ship as reusable packages (see
`packages/README.md`): Foundry contracts (`packages/contracts/`, import
`SweeftVault`/`SweeftDisputeBoard`/… directly), a Python client
(`packages/python/`, API reads + PQ message builders + mandate checks), and
an MCP server (`packages/mcp/`, the AI tools exposed read-only to agents).

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
