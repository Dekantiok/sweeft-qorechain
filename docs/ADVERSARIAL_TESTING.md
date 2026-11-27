# Sweeft Adversarial Testing Record

Every scenario below was executed; "Outcome" is the on-chain result actually
observed in Foundry (most are revert-equality + post-state assertions, never
bare-revert-only).

## Contract attacks (Foundry)

| Scenario | Expected rejection | Observed post-state | Test |
|---|---|---|---|
| Stolen verifier EVM key only | `BadVerifierSignature` | No attestation, nonce unconsumed | `SweeftVerifierPQ.t.sol#test_StolenEvmKeyAloneCannotAttest` |
| Replayed carrier signature | `BadCarrierSignature` (nonce advanced) | 1 attestation max | `SweeftCarrierDomain.t.sol` replay case |
| Replayed verifier signature | `AlreadyAttested` first | 1 count max | verifier PQ suite |
| Cross-chain carrier reuse | `BadCarrierSignature` | Unchanged escrow | carrier domain suite |
| Cross-contract carrier reuse | `BadCarrierSignature` | Unchanged escrow | carrier domain suite |
| Malicious carrier (status flip) | Only truthful status verifies | last-status rule explicit | carrier monotonic tests |
| Malicious verifier (wrong key) | `BadVerifierSignature` | Unchanged count | verifier PQ suite |
| Duplicate threshold filling | `AlreadyAttested` | Count stays 1 | verifier PQ suite |
| Unauthorized refund | Registry-refund gate (Funded+buyer sig) | Funds locked in dispute | vault release/refund suites |
| Unauthorized release | `NotReleaseEligible` / sig rejection | No credit movement | vault suites |
| Redirected recipient | Impossible by construction (recipient from storage) | Attacker credit 0 | `SweeftAdversarial.t.sol` |
| Altered amount | Creation-only funding; funded escrows immutable | InvalidStatus on re-fund | adversarial suite |
| DAO privilege escalation | allowlist + timelock + stake quorum | Rejects | `SweeftDAO2.t.sol` suite |
| Timelock bypass | `TimelockActive` pre-expiry | No execution | DAO2 suite |
| Panel manipulation | Timing grind eliminated (committed seed) | Deterministic draw | Phase 5 tests |
| AI spending bypass | Cap refusals, live amount | `within_caps=false` | `test_ai_tools.py`, live chat audit |
| Key revocation race | Pending signatures orphaned | Post-rotation sig fails | rotation test |
| Malicious token callback | No push payments anywhere in settle path | Reentrant receiver gains 0 | credits-only + invariant suites |
| Reentrancy (settlement) | Impossible (no external calls) | Invariant: balance ≤ escrowed | invariant suite |
| Nonce desync | Per-thing nonce pools (escrow/carrier/verifier) | Split-scope tests | all suites |

## Application attacks (Django)

- Negotiation at 5.0 QOR against a 0.5-cap mandate → refused (live-tested via chat).
- Spoofed model wallet → structurally impossible (server injection).
- Malformed/unpadded/mobile signatures → readable 401s, never 500.

Only attacks above were run; everything else is labeled analysis, not evidence.
