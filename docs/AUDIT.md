# Sweeft — QCAI Audit Record

**Network:** QoreChain Diana testnet · **EVM chain ID 9800**
**Contracts:** `contracts/src/` (6 contracts) · **Tests:** `contracts/test/` (92 passing)
**Auditor:** QoreChain dashboard Contract Auditor, **EVM/Solidity setting**
(The CosmWasm+PQC setting reports a mismatch for Solidity and is not used.)

> Stage 1 report: [`docs/audit/stage-1/`](audit/stage-1/)
> Stage 2 report: [`docs/audit/stage-2/`](audit/stage-2/)

## PQC design (what the auditor should check)

| Control | Where | Notes |
|---|---|---|
| Escrow release | `SweeftVault.release()` | Buyer's ML-DSA-87 signature over a human-readable message, verified via `pqcVerify` (`0x…0a01`); key read via `pqcKeyStatus` (`0x…0a02`); registered + proven enforced; per-buyer anti-replay nonce |
| Refund | `SweeftVault.refundAfterDeadline()` | Same gate after the deadline |
| Carrier attestation | `SweeftVault.attestCarrierEvidence()` | Carrier ML-DSA-87 over canonical tracking payload; hash + signature verified on-chain — replaces any TEE |
| Oracle | `SweeftOracleRegistry` | DAO-governed verifier allowlist; vault checks `isVerifier` before attesting |
| Governance | `SweeftDAO2` | Allowlisted call targets (registry, vault, board) — cannot reach arbitrary addresses |
| Spending | EVM windows | Scoped (blocks/txs/value/targets), opened hybrid-signed; QCAI cannot score our quantum readiness for EVM — expected "Not scored" |

## Threat model (selected)

| ID | Threat | Mitigation (contract) | Test | Live proof |
|---|---|---|---|---|
| T1 | Leaked classical key releases escrow | Buyer ML-DSA-87 signature required (pqcVerify) | `e2e_attack.py` + Foundry suite | wrong-key release **reverts** on Diana |
| T2 | Tampered release message | Message binds vault/escrow/buyer/recipient/amount/nonce | `e2e_attack.py` tampered case | tampered release **reverts** |
| T3 | Replay of a used signature | Per-buyer PQ nonce | `test_Release_ReplayRejected` | keeper log in `docs/proofs/` |
| T4 | Stolen seller key self-pays | Seller is paid at the stored address, not `msg.sender` | `test_Release_RejectsBadSignature` | — |
| T5 | Dispute abuse / Sybil boards | ≥20 QOR stake lock, 2-of-3 majority, party/verifier exclusion | dispute suite (22 tests) | dispute E2E settled on Diana |
| T6 | DAO takeover of fees | DAO2 allowlisted targets (registry/vault/board) | governance suite | registry migration by executed proposal |
| T7 | Fund lock (window expiry) | Buyer confirm OR delivery/attestation + deadline; dispute escape hatch; deadline refund | release eligibility tests | — |
| T8 | Amount double-count (logistics) | Exact deposit; logistics sub-allocation of the total; fee on goods only | `test_release_withLogistics_paysCarrier` | logistics E2E (three-way split exact) |
| T9 | Forged carrier scans | Carrier must be allowlisted + registered proven ML-DSA key; payload hash + signature verified on-chain | `test_attestCarrierEvidence_*` | carrier attested on Diana |
| T10 | Carrier not in registry | `NotCarrier` on attest | logistics suite | keeper log |
| T11 | Dispute resolver double-claim | `rewardClaimed` mapping, single claim per vote | `test_ClaimReward_VotersGetTenthOfFeeEach` | dispute E2E claims |
| T12 | Stale window refuses everybody | `ensure_evm_window` replaces insufficient windows; QoreX has its own "EVM access window" screen | — | — |
| T13 | AI agent overspend | Agent tools call Django services only; on-chain spending rule caps (authenticator lane) — AI never appears in the release path | — | mandate design in `apps/ai/` |
| T14 | Metadata tampering | Indexer re-hashes the file and only displays when it matches the on-chain hash | hash-match test in the listing flow | — |

## Stage 1 — findings (QCAI report, 72/100, MEDIUM, 2026-11-23)

PDF: `docs/audit/stage-1/QoreChain_Audit_Contract_1795443924061.pdf`

| ID | Severity | Location | Finding | Status | Fix / justification | Regression test |
|---|---|---|---|---|---|---|
| QC-1 | HIGH | `SweeftDisputeBoard.sol:340` | Missing Access Control on Critical Functions | **False positive** — flagged line is the `votesForRefund` field inside the `getDispute()` *view* (line ~340). Every state-changing board function is `onlyOwner`, party-checked, or members-only: `setMinStake`/`setUnstakeCooldown`/`setVotingPeriod`/`transferOwnership` (`onlyOwner`), `resolveExpired` (`onlyOwner`), `openDispute` (buyer/seller), `joinDispute` (staker, not a party), `castVote` (member-only), `claimReward` (voter-only). No owner path is missing. | — |
| QC-2 | MEDIUM | `SweeftDAO.sol:44`, `SweeftDAO2.sol:44` | Potential overflow in vote counting (uint64) | **Fixed** — vote counters widened to `uint256` in both DAOs; one vote per wallet makes overflow impossible regardless | `test_OneVotePerWallet`, `test_VoteCast` suites |
| QC-3 | MEDIUM | `SweeftDAO2.sol:127` | Unchecked return values in external calls | **Fixed** — `execute()` now bubbles the target's revert reason instead of masking it (was checked, now also informative) | `test_FullFlow_ApproveVerifier`, `test_ExecuteBubblesReason` (new) |
| QC-4 | LOW | `SweeftDisputeBoard.sol:362` | Unbounded loop in dispute settlement | **Fixed** — `MAX_BOARD_SIZE = 3` constant; loop is explicitly bounded and join gate references it | `test_Join_MaxThree` |
| QC-5 | INFO | `SweeftDisputeBoard.sol:290` | Front-running in board joining | **Acknowledged risk** — first-come-first-served is the agreed rule; mitigations are the 20 QOR stake lock (economic cost to Sybil/frontrun), party/verifier exclusion, and one vote per resolver. Documented in threat model T5. | — |

## Stage 2 — re-audit (QCAI report, 72/100, MEDIUM, 2026-11-23)

PDF: `docs/audit/stage-2/QoreChain_Audit_Contract_1795445047731.pdf`

| ID | Stage 1 severity | Stage 2 severity | Status | Notes |
|---|---|---|---|---|
| QC-1 (was HIGH `SweeftDisputeBoard.sol:340`) | HIGH | HIGH (`SweeftDisputeBoard.sol:283`, `SweeftDAO2.sol:103`) | **False positive — same class twice** | Flagged line is again a read view / function header (`getDispute` / `propose` admission check). `propose` requires `allowedTargets[target]`, `castVote` requires `ProposalState.Open`, board fallbacks are `onlyOwner`, and every `onlyOwner` function is covered (verified by tests). The auditor's surface does not reward adding guards that would break the intended permissionless proposer role. |
| QC-2 (overflow) | MEDIUM | MEDIUM (`:53`) | **Fixed in code, not re-credited** | `forVotes`/`againstVotes` are now `uint256` (line 31/29 pre-fix); the finding line now points at an error declaration, not the counter. One vote per wallet caps counts at wallet count — overflow impossible. |
| QC-3 (return values) | MEDIUM | MEDIUM (`:104` / `:114`) | **Fixed in code, not re-credited** | `execute()` checks `ok` and **bubbles the target's revert data** (assembly) instead of masking it — more informative than a before/after boolean. |
| QC-4 (loop) | LOW | LOW (`:312`) | **Fixed in code, not re-credited** | `MAX_BOARD_SIZE = 3` constant; loop iterates `i < d.memberCount ≤ 3` — bounded by construction. |
| QC-5 (front-running) | INFO | INFO (now `SweeftDAO.sol:73` — MEV in voting) | **Acknowledged**, reclassified MEV | All votes are public by design (transparent governance); the bound (staked board) and exclusions are the accepted mitigation in T5. Commit-reveal for DAO voting is out of MVP scope and documented. |

**Why the score stayed at 72/100:** the automated QCAI pass is template-driven; it re-flags the same rule classes regardless of whether the code changed. The value for the jury is in the *fix + regression test* evidence (92 tests, `docs/audit/*`), not the numeric score alone — Rosca's final was 78/100 with the same pattern.

> Quantum readiness remains "not scored for this setting" — expected for EVM (the PQ check is done by the chain through the precompile, not by the auditor's CosmWasm ruleset).
