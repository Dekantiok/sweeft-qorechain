# Sweeft Security Remediation Record

Audience: auditors, jury, and integrators. Every entry names the finding,
the fix, and the test that proves it. Nothing here is claimed without
evidence; unproven items are marked as documented limitations.

## Carrier domain separation (G2)

- **Finding:** carrier messages bound only `(provider, tracking, escrow,
  status, issued, nonce)` — no chain, vault, or carrier address; cross-vault
  replay inside the 7-day freshness window.
- **Fix:** `sweeft-carrier-v2` domain (`docs/POST_QUANTUM_SECURITY.md §5`),
  nonce consumed only after validation, expiry pinned on-chain, removed
  carriers lose authority.
- **Tests:** `SweeftCarrierDomain.t.sol` — 15 cases (valid, invalid, wrong
  carrier/escrow/vault/chain, expired, replayed, six mutations, unauthorized
  carrier, removed carrier, widened expiry).
- **Remaining limitation:** same-deployment same-nonce carrier self-replay
  needs carrier collusion; accepted as attested-trust scope.

## PQ verifier attestations (G1, Critical)

- **Finding:** `attestEvidence` authorized by `msg.sender` + registry only;
  a stolen verifier EVM key could forge attestations (refund blocked, forced
  dispute path).
- **Fix:** signed `sweeft-verifier-v1` authorization over the verifier's
  chain-registered ML-DSA-87 key; relayer submissions allowed; registry
  pins key version + timestamp at `addVerifier`; `rotateKeyVersion`
  re-pins. Classical-only attacks rejected by construction.
- **Tests:** `SweeftVerifierPQ.t.sol` — valid PQ, classical-only, wrong key,
  unregistered, revoked, expired, duplicate, replayed, mutations,
  threshold reachability, double-seat, stolen-key scenario, rotation
  invalidation, revocation permanence.
- **Remaining limitation:** signature authority still depends on the chain
  PQ-key registry's provenance (chain-side guarantee, §15 assumptions).

## Governance allowlist re-check (G6)

- **Finding:** allowlist enforced at `propose` but not at `execute` — a
  passed proposal could run a revoked selector later.
- **Fix:** `execute` re-checks target + selector before the timelock check.
- **Tests:** `test_Execute_RevokedCallReverts`, `test_Execute_RevokedTarget_BlocksExecution`,
  `test_Veto_AfterTimelock_Reverts`, `test_Direct_TreasuryChangeByNonOwner_Reverts`.

## Dispute randomness (G3)

- **Finding:** `selectPanel` seed = call-time `block.prevrandao` — a party can
  timing-grind panel selection across a 48h window.
- **Fix:** future-block seed (`drawBlock = open + 16`) chained with
  capture-time prevrandao; caller timing never enters the seed; 256-block
  checkpoint window with liveness fallback.
- **Tests:** too-early seed, stale-window checkpoint revert, stale fallback
  draw, one-shot draws.
- **Remaining limitation:** single-validator bias on the capture/draw block
  (~1 bit); bounded by stake + appeal economics, documented in AUdit.

## Key lifecycle (G-residual)

- Registry: initial registration pins algorithm (must be ML-DSA-87) +
  timestamp; `rotateKeyVersion` re-pins; revocation blocks attestations,
  past attestations stand. Buyer keys are chain-managed in QoreX.
- **Tests:** `test_KeyRotation_KillsPendingAttestations`,
  `test_Revocation_KeepsCountButBlocksNew`.

## AI mandate paths (G8)

- **Live-amount check**: caps now checked against `escrow_state` (chain),
  not the indexer mirror.
- **Opt-in autopilot flag**: mandates must explicitly allow autonomous
  execution (`autopilot_allowed`), or executions refuse.
- **Floor anti-leak**: negotiation counters banded (0.05 QOR);
  accepted terms write PLANNED spend rows against the daily cap.
- **Prompt-injection posture**: tool output delimited as UNTRUSTED data;
  the model cannot supply `wallet` (server-injected).
- **Tests:** `tests/test_ai_tools.py` (negotiation floors/caps/units) +
  existing mandate suites.

Earlier hardening (carried, original AUDIT.md): reentrancy-in-release
(credits-only), C-1 DAO params, N-1/N-2 fund-loss gates, M-of-N fail-closed,
fee snapshots, marketplace pinning, Slither/pip-audit triage.
