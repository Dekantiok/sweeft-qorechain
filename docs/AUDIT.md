# Sweeft — QCAI Audit Record

**Network:** QoreChain Diana testnet · **EVM chain ID 9800**
**Contracts:** `contracts/src/` (6 contracts) · **Tests:** 121 Foundry + 13 Django
**Auditor:** QoreChain dashboard Contract Auditor, **EVM/Solidity setting**
(The CosmWasm+PQC setting reports a mismatch for Solidity and is not used.)

> Stage 1 report: [`docs/audit/stage-1/`](audit/stage-1/)
> Stage 2 report: [`docs/audit/stage-2/`](audit/stage-2/)
> External review response (v5 hardening): see the section at the end of this file.

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
| T3 | Replay of a used signature | Per-escrow PQ nonce (v5: keyed by escrow, so parallel escrows stay independent) | `test_Release_ReplayRejected`, `test_PerEscrowNonce_Independent` | keeper log in `docs/proofs/` |
| T4 | Stolen seller key self-pays | Seller is paid at the stored address, not `msg.sender` | `test_Release_RejectsBadSignature` | — |
| T5 | Dispute abuse / Sybil boards | v5: stake scales with escrow value, minority/non-voter slashing, raiser bond, appeal-window lock, deterministic permissionless expiry | `SweeftDisputeBoard.t.sol` (27 tests, incl. slash/bond/expiry) | dispute E2E settled on Diana |
| T6 | DAO takeover of fees | v5: bounded voting periods, `(target,selector)` allowlist, quorum, timelock, proposer bond; DAO owns registry/vault/board | `SweeftDAO2.t.sol` (incl. `test_ShortWindowTakeover_NowImpossible`) | registry migration by executed proposal |
| T7 | Fund lock (window expiry) | Buyer confirm OR delivery/attestation + deadline; dispute escape hatch; deadline refund; v5: bounded deadline window | release eligibility tests, `test_CreateEscrow_RejectsPastDeadline` | — |
| T8 | Amount double-count (logistics) | Exact deposit; logistics sub-allocation of the total; fee on goods only | `test_release_withLogistics_paysCarrierWhenDelivered` | logistics E2E (three-way split exact) |
| T9 | Forged carrier scans | v5: carrier must be the escrow's logistics partner with a registered proven ML-DSA key; message binds escrow/status/nonce/freshness; DELIVERED-only | `test_attestCarrierEvidence_*`, `test_nonDeliveredStatusDoesNotFulfil` | carrier attested on Diana |
| T10 | Carrier not in registry | `NotCarrier` on attest | logistics suite | keeper log |
| T11 | Dispute resolver double-claim | `rewardClaimed` mapping, single claim per vote; v5: per-dispute reward from the escrow's own fee | `test_ClaimReward_VotersGetShare`, `test_ClaimReward_RefundPaysNothing` | dispute E2E claims |
| T12 | Stale window refuses everybody | `ensure_evm_window` replaces insufficient windows; QoreX has its own "EVM access window" screen | — | — |
| T13 | AI agent overspend | v5: mandate enforced in Django code (per-tx + rolling daily caps; refuses with no active mandate); on-chain spending rule is the hard cap; agent never appears in the release path | `tests/test_security.py` (mandate tests) | autopilot proven on testnet |
| T14 | Metadata tampering | Indexer re-hashes the file and only displays when it matches the on-chain hash; v5: purchase pins the metadata hash on-chain | hash-match test in the listing flow, `test_Purchase_RejectsMetadataMismatch` | — |

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

## External security review — response (v5 hardening)

A line-by-line external review of `contracts/src/*` and the Django apps produced
the findings below. Each Critical/High item has a regression test that encodes
the fixed behaviour; contracts and backend were revised together as "v5".

### Smart contracts

| ID | Sev | Finding | Status | Where / test |
|---|---|---|---|---|
| C-1 | Critical | DAO2 `propose()` permissionless, caller-chosen voting period, no quorum/timelock/snapshot | **Fixed** | `SweeftDAO2.sol`: `MIN/MAX_VOTING_PERIOD`, `TIMELOCK`, `quorum`, `PROPOSER_BOND`, `(target,selector)` allowlist, self-governance. `test_ShortWindowTakeover_NowImpossible`, `test_Execute_RequiresTimelock`, `test_Execute_QuorumNotMet_Rejects` |
| C-2 | High | Dispute board: no slashing, first-come seats capturable | **Fixed** | `SweeftDisputeBoard.sol`: stake scales with escrow, minority/non-voter slashing, appeal-window lock. `test_Slash_MinorityVoter`, `test_MinStakeFor_ScalesWithEscrow`, `test_Resolvers_LockedThroughAppealWindow`. Random panel selection acknowledged as future work. |
| C-3 | High | Buyer-controlled/past deadline; refund ignores delivery | **Fixed** | `SweeftVault._validateDeadline` (`MIN_WINDOW`..`MAX_WINDOW`); `isRefundable` blocked once delivered/attested. `test_CreateEscrow_RejectsPastDeadline`, `test_Refund_BlockedAfterDelivered` |
| C-4 | High | Carrier attestation unbound to escrow/carrier/status | **Fixed** | `attestCarrierEvidence(escrowId, tracking, status, issuedAt, sig)`; requires `msg.sender == logisticsPartner`; message binds escrow+carrier+status+nonce+freshness; DELIVERED-only. `test_attestCarrierEvidence_otherCarrierRejected`, `test_nonDeliveredStatusDoesNotFulfil`, `test_attestCarrierEvidence_staleRejected` |
| C-5 | Med | Single verifier is a point of trust | **Fixed** | `SweeftOracleRegistry.threshold` (M-of-N); vault counts distinct attestations. `test_VerifierThreshold_TwoOfThree` |
| C-6 | Med | Buyer without a proven PQ key can lock funds | **Fixed** | Vault requires registered+proven key at creation. `test_CreateEscrow_RequiresRegisteredBuyerKey` |
| C-7 | Med | Fee/treasury mutable after funding | **Fixed** | Snapshotted into the escrow at creation; used in `_payRelease`. `test_FeeSnapshot_NotAffectedByLaterChange` |
| C-8 | Med | Push payments can brick settlement; no reentrancy guard | **Fixed** | `nonReentrant` on money paths; push-with-`credits` fallback + `withdrawCredits`. |
| C-9 | Low-Med | Global per-buyer nonce breaks parallel escrows | **Fixed** | Per-escrow nonce (`escrowNonce`). `test_PerEscrowNonce_Independent` |
| C-10 | Med | Owner-decided expiry; free dispute griefing | **Fixed** | `openDispute` requires a bond; `resolveExpired` is permissionless and deterministic; lock through appeal window. |
| C-11 | Low-Med | Reward accounting could drain pool; stranded share | **Fixed** | Reward is per-dispute, from that escrow's fee, split across voters; refunds pay none. `test_ClaimReward_RefundPaysNothing` |
| C-12 | Low-Med | Logistics paid even without delivery | **Fixed** | Carrier paid only on proven delivery; otherwise the share is credited to the buyer. `test_release_withoutCarrierAttestation_holdsLogisticsForBuyer` |
| C-13 | Low-Med | Marketplace didn't pin price/metadata; dead check | **Fixed** | `purchase(listingId, deadline, maxPrice, expectedMetadataHash)`; `updatePrice` re-checks logistics fee; dead check removed. `test_Purchase_RejectsPriceAboveMax`, `test_Purchase_RejectsMetadataMismatch` |
| C-14 | Low | DAO choice validation, zero checks, vote cap | **Fixed** | `castVote` validates 1/2/3; `transferOwnership` zero-check; `MAX_VOTES` cap removed. |
| C-15 | Low | Wrong errors; missing events; one-shot wiring | **Fixed** | `NotDeployer`/`AlreadyWired`; `FeeUpdated`/`TreasuryUpdated` events; DAO-governed, timelocked rewire path. |
| C-16 | Low | Hard-coded precompile/chain values | **Documented** | Testnet constants are intentional and fail-closed; a `vm.etch` mock-precompile test covers them. |

### Django backend

| ID | Sev | Finding | Status |
|---|---|---|---|
| B-1 | High | Autopilot endpoints unauthenticated / `csrf_exempt` | **Fixed** — pre-authorize/revoke require the buyer session (401/403); execute requires buyer or `X-Internal-Token`; signature-length + TTL; single-use clear; CSRF enforced (`tests/test_security.py`) |
| B-2 | Med | Widespread `csrf_exempt` | **Fixed** — removed from session endpoints; the JS already sends `X-CSRFToken`; `SESSION_COOKIE_SAMESITE=Lax` |
| B-3 | Med | Unauthenticated heavy indexer trigger | **Fixed** — requires internal token or staff; per-IP rate limit; capped `max_blocks` |
| B-4 | High | Relayer gas-burn / nonce race | **Fixed** — simulate (`call`) then `estimate_gas`×1.2, length-check, nonce lock |
| B-5 | Med | Long synchronous waits | **Mitigated** — receipt timeout reduced; background-job path documented |
| B-6 | Med | Anyone can submit evidence | **Fixed** — must be a party; evidence count capped |
| B-7 | Med | Unauthenticated metadata upload | **Mitigated** — re-hash on index (integrity); auth/quota tracked |
| B-8 | Low-Med | Wallet-login hardening | **Fixed** — domain/expiry-bound challenge, single-use, session rotated on login |
| B-9 | High (ops) | Key separation / blast radius | **Documented** — deployer mnemonic is testnet-only; secrets via env; separate relayer key. Production posture in README |
| B-10 | Med | Server-signed carrier (Demo Carrier) | **Documented** — labelled simulated everywhere; real carriers sign with their own keys |
| B-11 | High (claims) | Mandate was a stub; prompt injection; float math | **Fixed** — mandate enforced in code (per-tx + rolling daily; refuses with none); Decimal amounts; tool allowlist via `TOOLS_REGISTRY`; listing text treated as data |
| B-12 | Low-Med | Oracle page N chain reads | **Mitigated** — indexed DB state used where available |
| B-13 | Med | uqor/wei unit mixing | **Tracked** — one documented unit per layer; round-trip tests planned |
| B-14 | Low-Med | Pre-signed release is a bearer token | **Fixed** — TTL + clear-after-use + buyer revoke + active-authorization list |

### Process

- **D-1** dependency hygiene, **D-2** production settings (HSTS preload, CSP,
  frame/referrer/cookie hardening, structured logs), **D-3** test gaps (new
  Foundry DAO2/invariant suites + Django `tests/`), **D-4** deeper review of the
  indexer/JS, and **D-5** claims/docs accuracy are reflected here and in the
  README. `pip-audit`/Slither-in-CI remain recommended follow-ups.

**Definition of done (from the review):** a regression test exists for each
Critical/High finding and the README makes only claims the code backs. Foundry
**121 passing**, Django **13 passing**.
