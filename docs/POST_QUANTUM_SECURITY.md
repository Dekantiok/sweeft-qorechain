# Sweeft Post-Quantum Security Model

## 1. Cryptographic threat model

Adversaries under consideration, in increasing strength:

1. **Classical-only attacker** — holds secp256k1 keys (stolen seed, leaked
   mnemonic) but not ML-DSA-87 keys. **CANNOT move escrowed funds, cannot
   attest, cannot settle disputes, cannot govern** (all gates equal this
   attacker). This is Sweeft's core design target.
2. **Colluding parties** — buyer + seller + partial resolver cartels acting
   together. Bounded by stake economics (20 QOR + 100% escrow stake, slash
   on overturn) and the appeal path.
3. **Malicious carrier/verifier holding their own PQ keys** — signatures
   are valid but the *facts* are false. This is attested-trust risk, not
   key-compromise risk (see §11 limitations).
4. **Block proposer manipulation** — wins at most ~1 bit of randomness bias
   on the draw-block checkpoint; priced by stake + 50% overturn slash.
5. **Prompt-injection against the AI** — wasted if it can't produce valid
   signatures or spend above caps (enforced server-side, not by model).

## 2. The role of ML-DSA-87

Every fund-movement authorization in Sweeft is an ML-DSA-87 signature
verified **by the contract** via QoreChain's `pqcVerify` precompile
(`0x…0a01`), against the buyer's/verifier's/carrier's chain-registered key
read via `pqcKeyStatus` (`0x…0a02`, which demands a registered + proven key).
A classical signature can open/close windows and move EVM gas, but it cannot
authorize: escrow release, refund, carrier attestation, or verifier
attestation. Releases are permissionlessly submittable precisely because the
signature is the authorization — `msg.sender` carries no authority.

## 3. The role of classical EVM accounts

Classical accounts retain three legitimate powers: (a) **funding** escrows
(`createEscrow`, `fundEscrow`); (b) **arbitrary submission** of
signature-authorized calls (relayers); (c) **own-credit withdrawal**
(`withdrawCredits`). They NEVER authorize settlement, attestation, or
governance execution by themselves.

## 4. Buyer authorization

`_releaseMessage` / `_refundMessage` bind `(vault, escrow, buyer,
recipient, amount, nonce)`; `qorechain-msg-v1|<cosmosChainId>|` is prepended
on-chain. Only settlements deriving from stored escrow state, consumed per-
escrow nonce, one terminal settlement per escrow.

## 5. Carrier authorization

`attestCarrierEvidence` now requires a domain-separated `sweeft-carrier-v2`
signature `(protocol, schema, chain, vault, carrier, provider, escrow,
tracking hash, status, evidence, issued, expiry, nonce)`. Expiry is pinned
to `issuedAt + MAX_ATTEST_AGE` on-chain; the nonce is consumed only after
all validation; removed carriers lose authority. Only `DELIVERED` is proof —
anything else opens the refund path.

## 6. Verifier authorization

Registry pins each verifier's ML-DSA algorithm + timestamp at approval;
attestations are signed `sweeft-verifier-v1(…)` messages verified under the
verifier's chain-registered key, counted once per verifier per escrow
toward an M-of-N threshold. Revoked verifiers revert (`NotVerifier`);
rotated keys orphan pending signatures (re-pin required).

## 7. DAO authorization

Ownership web: Vault/Registry/Board/DAO2 all owned by `SweeftDAO2`
(executed proposals only). Stake-weighted votes (QOR escrowed with the vote,
locked until final), proposer bond, allowlist re-checked at `execute`,
timelock, guardian veto. Per-vote PQ signatures: evaluated and rejected as
unnecessary friction (economic stake is the Sybil control). SweeftDAO v1
is deployed but inert.

## 8. Key registration and rotation

Registration proofs and possession checks live in QoreChain/QoreX; the
protocol consumes the chain registry. Rotation = re-pin via
`rotateKeyVersion` after a new registered key exists. Pending signatures
don't survive rotation; settled escrows are historical artifacts and never
depend on the current key. No private keys are ever stored in contracts,
Django records, or logs.

## 9. Replay protection

Per-escrow nonce (release/refund share a pool — first settles), per-
(carrier,escrow) nonce, per-(verifier,escrow) nonce, expiry windows inside
the signed bytes, versioned domain prefixes (`sweeft-release-v1`,
`-refund-v1`, `-carrier-v2`, `-verifier-v1`). Cross-action and cross-
contract replay is structurally impossible (tested).

## 10. Signature domain separation

All formats are single-protocol `v1`/`v2` strings with labeled fields in a
fixed order, deployed at `qorechain-diana`. A signature minted for one
deployment/chain/escrow/verifier is invalid anywhere else — proven by the
carrier/verifier domain test suites.

## 11. Oracle threshold verification

M-of-N (`threshold` capped at `verifierCount`, minimum 1). The Vault reads
threshold + membership from the registry and fails closed (`RegistryUnavailable`)
if the registry cannot be read. Verifier bond removal (slash) exists for
provably false attestations.

## 12. Dispute randomness

Seeds commit to a **fixed future block** (`drawBlock = open + 16`) chained
with the capture-time prevrandao; `blockhash` checkpointed by anyone within
256 blocks (capture-seed fallback keeps liveness). Callers cannot timing-
grind panel draws. Residual: a single validator could bias its own block
once — priced by 100%-of-escrow stake and 50% overturn slash.

## 13. AI mandate boundaries

Budgets are Django-enforced only (see §15 note), opt-in autopilot execution
flag, wallet server-injected (N-11), tool-output delimiting against prompt
injection, banded negotiation counters (anti floor-leak), PLANNED ledger
reserved against the daily cap. Drafts never publish; settlement always
needs wallet signatures.

## 14. Known limitations

- Autopilot bearer signatures live until consumed (Django TTL only). The scope
  is frozen on-chain, so the worst case is early settlement, never redirection.
- `block.prevrandao` at capture moment: bounded-by-economics residual.
- Carrier attestation window is 7 days; `issuedAt` is signer-claimed.
- Demo Carrier (`LOG-DEMO-001`) is simulated and production carriers need a
  `DEMO_CARRIER_MNEMONIC` isolated key; the relayer fallback is only for dev.
- AI daily accounting relies on the tool layer writing accurate spend rows;
  new tools must write `AgentAction` rows or caps will undercount it.
- SweeftDAO (v1) remains deployed but inert (owns nothing; immutable target).

## 15. Security assumptions (testnet)

- The PQC precompiles implement ML-DSA-87 correctly and expose true
  registration/provenance data.
- Validator sets don't collude beyond one withheld block per disputed slot.
- Testnet tokens are worthless; mainnet value would require the QCAI human
  review + value-at-risk staging the audit trail explicitly withholds.
