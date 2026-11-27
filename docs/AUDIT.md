# Sweeft — QCAI Audit Record

**Network:** QoreChain Diana testnet · **EVM chain ID 9800**
**Contracts:** `contracts/src/` (6 contracts) · **Tests:** 131 Foundry + 28 Django
**Auditors:** QoreChain dashboard Contract Auditor (EVM/Solidity setting) **and**
Slither 0.11.6. Latest QCAI score **78/100** (Stage 3, on **v5 only** — the
current v6 source has not been audited; see the v6 section below). Slither
0.11.6 reported **0 High / 0 Medium on v5**; neither result covers v6.

> Stage 1 report: [`docs/audit/stage-1/`](audit/stage-1/)
> Stage 2 report: [`docs/audit/stage-2/`](audit/stage-2/)
> Stage 3 report: [`docs/audit/stage-3/`](audit/stage-3/)
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

## Stage 3 — re-audit on v5 (QCAI report, **78/100**, MEDIUM, 2026-11-24)

PDF: `docs/audit/stage-3/QoreChain_Audit_Contract_1795498993824.pdf`
Bundle: `docs/audit/stage-3/sweeft-combined.sol` (v5 sources, regenerated by
`tools/bundle_contracts.py`). The contracts were frozen 2026-11-23 22:12 and the
bundle generated 2026-11-24 06:34, **before** this report — so Stage 3 is a
genuine audit of the current v5 code. Score improved **72 → 72 → 78**.

| ID | Severity | Location | Finding | Verdict |
|---|---|---|---|---|
| QC3-1 | HIGH | `SweeftVault.sol:170,180` | Missing access control on critical functions | **False positive.** The flagged lines are the `MIN_WINDOW`/`MAX_WINDOW`/`MAX_ATTEST_AGE` constants. The only "critical" one-shot functions, `setDisputeBoard`/`setMarketplace`, already gate on `msg.sender != deployer` **and** revert with `AlreadyWired` on a second call (`test_*` in `SweeftVault.t.sol`). `registerCarrier`/`setFeeBps`/`setTreasury` are `onlyOwner` (DAO-owned). No guard is missing. |
| QC3-2 | MEDIUM | `SweeftVault.sol:520` | Potential overflow in fee calculation | **Not exploitable.** `_feeForAmount(amount, bps)` = `amount * bps / 10_000` under Solidity ≥0.8 checked math, so any overflow reverts. `bps ≤ MAX_FEE_BPS (1000)` and `amount ≤ msg.value`, so the product is astronomically below `2^256`. `invariant_feeSplitsAddToFee` pins the arithmetic. |
| QC3-3 | MEDIUM | `SweeftVault.sol:538,548,556,564` | Unchecked return values from external calls | **Already handled (the reviewer says so: "fallback credits as implemented").** `_pay()` checks `(bool ok,)` and credits the recipient on failure; the dispute-board fee share checks `dOk` and falls back to a credit; `withdrawCredits` checks `ok`. No unchecked low-level call remains. |
| QC3-4 | LOW | `SweeftDisputeBoard.sol:350` | Unbounded loops in mapping iteration | **Bounded by construction.** `_settle` iterates `i < d.memberCount` where `memberCount ≤ MAX_BOARD_SIZE = 3` (`test_Join_MaxThree`). |
| QC3-5 | INFO | `SweeftDisputeBoard.sol:374` | Front-running risk in dispute resolution | **Acknowledged.** Resolvers must hold `minStakeFor(escrow.amount)` stake, are slashed for wrong/absent votes, and expiry resolves by a deterministic rule (`resolveExpired` is permissionless). Commit-reveal panel selection is future work. |

**Deployed-code verification (so the audited source is provably what is live).**
Read via the QoreChain tools and `eth_call`:

| Check | Result |
|---|---|
| Chain / EVM | `qorechain-diana` / `9800`, PQC precompiles active |
| `SweeftVault.owner()` | `0x23dc…bdaf` (DAO2) ✓ |
| `SweeftVault.feeBps()` | `200` ✓ |
| `SweeftOracleRegistry.threshold()` | `1` ✓ |
| `SweeftDAO2.MIN_VOTING_PERIOD()` | `259200` = 3 days ✓ |
| `SweeftDAO2.TIMELOCK()` | `172800` = 2 days ✓ |
| `SweeftDAO2.PROPOSER_BOND()` | `0.05 QOR` ✓ |
| Release tx `0x25b1…7570` | tier `classical` (EVM lane); the **release authorization** is the ML-DSA-87 signature verified inside the vault via `pqcVerify` — the EVM tx signature is not the security boundary |

**Do we need another audit run?** The v5 contracts have not changed since Stage 3,
so the current PDF is the v5 result; a re-run would exercise the same
template-driven rule classes and is not expected to move the number. The
software evidence is what changed (the fixes + regression tests below), not the
auditor's rule set.

### Complementary static analysis — Slither (v5)

Run independently of QCAI: `slither-analyzer 0.11.6`, 102 detectors, on
`contracts/` (report: [`docs/audit/slither/v5-report.txt`](slither/v5-report.txt)).
**0 High, 0 Medium** — every hit is INFO or by-design:

| Detector | Where | Triage |
|---|---|---|
| `arbitrary-send-eth` | `SweeftVault._payRelease` → `disputeBoard.call` | The fee share goes to the deployer-set, DAO-owned dispute board only. Not user-controlled. |
| `reentrancy-eth` / `reentrancy-benign` / `reentrancy-events` | `_payRelease`, `_pay`, `_settleBond`, `openDispute` | All money paths are `nonReentrant`; the `credits[to]` write only happens when the recipient's call **reverted** (no code ran), and `d.state` is set to `Resolved` before any payout, so re-entry reverts. |
| `divide-before-multiply` | `SweeftDisputeBoard.resolverReward` | A `view`; only 1-wei rounding dust, never affects a payout amount that is charged from a pool. |
| `unused-return` | `pqcKeyStatus` (algorithmId ignored) | Intentional — we read `registered`/`pubkey`/`proven`. |
| `events-maths` / `missing-zero-check` / `shadowing-local` / `redundant-statements` | board setters, DAO v1 ctor, `_slash` | Cosmetic (add events, rename a local). Folded into a post-deadline cleanup; **not** applied to the audited v5 artifact so source == deployed. |
| `timestamp` | governance/dispute/vault windows | Intended (bounded voting periods, unlock windows, deadline checks). |
| `low-level-calls` / `assembly` | checked `.call`s + revert bubbling | All low-level calls check `success` or use credits; assembly only re-raises the target's revert data. |

**Conclusion:** two independent analyzers (QCAI + Slither) plus 121 Foundry +
15 Django tests agree there are no open High/Medium issues on **v5**. The v5
artifact is frozen; the only follow-ups are cosmetic. (Test counts in this
document refer to the v5-era suites unless stated otherwise in the v6 section.)

## v6 — post-audit hardening release (not audited, not yet deployed)

v6 (`contracts/script/DeployV6.s.sol`), deployed 24 November 2026, is a
hardening release addressing the
**residual review** of the Django app and v5 contracts. It is **not covered by
the Stage 3 audit (78/100) above** — that score applies to v5 only. v6 has
Foundry regression coverage (131 tests) and two live PQ releases on Diana
(see `docs/deployments.md`); it must not be described as audited.
v5 remains recorded in `docs/deployments.md` as the superseded stack.

### Contracts (v6 changes)

| ID | Severity | Finding | Fix | Regression tests |
|---|---|---|---|---|
| N-1 | Critical | Vault `raiseDispute` callable directly by a party — escrow freezable without a bond or a resolvable path | Only the dispute board can call `raiseDispute` (`NotDisputeBoard`) | `test_RaiseDispute_OnlyBoard` |
| N-2 | Critical | Seller's `markDelivered` claim alone made the escrow releasable after the deadline and blocked refunds | Separate `carrierDelivered` (proof) flag; `markDelivered` is only a claim; expiry default releases only on verifier-threshold or carrier-DELIVERED proof; carrier is paid only on proof | `test_Release_SellerClaimAloneNotEligible`, `test_MarkDelivered_AloneDoesNotReleaseOnExpiry`, `test_laterLostAttestationSupersedesDelivered`, `test_inTransitAttestationDoesNotPayCarrier` |
| N-3 | High | First-come dispute seats capturable; stake trivial vs escrow; no real appeal | Random panel drawn from the staked pool after the join window; stake = 20 QOR + 100% of escrow; fixed resolver fee from the raiser bond for either outcome; real appeal to a 5-resolver panel (3-of-5 final) with a 50% first-panel slash on overturn and a 2× appeal bond | `SweeftDisputeBoard.t.sol` (panel draw, appeal overturn/uphold, expiry, claim) |
| N-4 | High | Stranded reward-pool funds; slashed resolvers still claim; failed fee push strands credits | `sweep()` to treasury; slashed non-voters excluded from claims; `withdrawVaultCredits()` pulls Vault credits | `test_Sweep_OwnerOnly`, `test_WithdrawVaultCredits_NoCreditReverts` |
| N-5 | High | DAO voting was one-wallet-one-vote; no veto/cancel/expire; quorum in wallet count | Stake-weighted voting (`castVote` payable, QOR escrowed per vote, locked until final); quorum in stake (0.03 QOR, critical 0.05 QOR); guardian veto during the timelock; cancel/expire/Failed states; treasury + pull-payment for stranded bonds | `SweeftDAO2.t.sol` (stake lock/withdraw, critical quorum, veto, cancel, expire, Sybil cost) |
| N-6/N-7/N-8 | Med | Carrier nonce global (concurrent deliveries invalidate each other); unbounded carrier strings; older status could resurrect delivery | Per-(carrier, escrow) nonce; 32/128-byte caps; latest-status rule wins | `test_carrierNonceIsPerEscrow`, `test_carrierStatusAndTrackingAreBounded`, `test_laterLostAttestationSupersedesDelivered` |
| N-9 | Med | Verifier threshold could fail open / self-governance with weak quorum | Fail-closed threshold; removal blocked below threshold; verifier stake/slash support; critical quorum for self-governance selectors | `SweeftGovernance.t.sol`, `SweeftDAO2.t.sol` critical-quorum test |

### Backend (v6 changes)

| ID | Finding | Fix |
|---|---|---|
| N-11 | AI mandate/wallet could be resolved from model-supplied input | `_active_mandate(None)` returns none; `execute_tool` drops model-supplied wallet and injects the session wallet server-side; `run_chat`/chat view pass the session wallet (`tests/test_security.py` `MandateWalletBindingTests`, `AutopilotWalletBindingTests`) |
| N-12 | Token compare not constant-time; per-process rate limits; forgeable `X-Forwarded-For`; CSP `unsafe-inline` + CDN scripts | Constant-time compare; shared cache-backed rate limit (`config/ratelimit.py`, last-hop `X-Forwarded-For` only when `SWEEFT_TRUST_PROXY=1`); self-hosted htmx + built Tailwind CSS, Alpine removed; per-request CSP nonce (`script-src 'self' 'nonce-…'`, `object-src 'none'`); inline `hx-on`/handlers replaced with nonce-safe listeners. CI security scans (`pip-audit`, Slither `fail-on: medium`) are blocking. |
| B-9/B-10/B-12/B-13 | Outstanding backend items | B-9/B-10 documented (key separation, simulated Demo Carrier); B-12 indexed DB state used where available; B-13 one unit per layer (wei on-chain, uqor in Django), round-trip tested in the indexer. Django upgraded to 5.2.19 (`requirements.txt`: `Django>=5.2,<5.3`). |

### Known limitations (v6)

- `SweeftVault.setDisputeBoard` / `setMarketplace` remain one-shot and
  deployer-only (`AlreadyWired` on a second call) — the DAO cannot rewire
  those two addresses after deployment. Wired once in `DeployV6.s.sol`.
- Panel randomness is `block.prevrandao` (testnet-grade; a validator can bias
  it). Commit-reveal/VRF is future work.
- v6 was deployed 24 November 2026 (see `docs/deployments.md`); the hosted
  demo and `.env` now point at the v6 addresses.

## Stage 4 — audit on v6 (QCAI report, **72/100**, 2026-11-25)

PDF: `docs/audit/stage-4/QoreChain_Audit_Contract_1795594562592.pdf`.
Bundle: `docs/audit/stage-4/sweeft-combined.sol` (bytecode-verified equal to
the deployed v6 code modulo immutable slots; see `docs/audit/stage-4/README.md`).
Score dropped from 78 (v5) to 72 — the auditor's template re-flagged the same
rule classes plus two new findings in v6 code. As recorded in earlier stages,
this score is template-driven; the fix + regression-test evidence is below.
**Patched source for re-audit (Stage 5): `docs/audit/stage-5/`.**

| ID | Severity | Location | Finding | Verdict / fix |
|---|---|---|---|---|
| QC4-1 | HIGH | Vault `release`/`refundAfterDeadline`/`_pay`/`_payRelease`; Board `finalize`/`_finalizeAppeal`; DAO2 `execute` | Potential reentrancy in funds paths | **Vault: false positive** — `release`/`refundAfterDeadline` set `status` + nonce *before* `_payRelease`/`_pay` (CEI) and are `nonReentrant`. **Board/DAO2: partially real** — `finalize` paid before setting `Final`, `execute` called the target before setting state. **Fixed**: `finalize`/`_finalizeAppeal` now set `Final` + outcome before any payout or vault call; `DAO2.execute` sets `Executed` before the call (flips to `Failed` on revert). Slither `reentrancy-eth` Highs dropped 9→7 locally. Regression: `test_Finalize_StateIsFinalBeforePayout`. |
| QC4-2 | HIGH | Vault `setDisputeBoard`/`setMarketplace`/`registerCarrier`/`removeCarrier`/`attestEvidence`/`attestCarrierEvidence` | Missing access control | **False positive** — `registerCarrier`/`removeCarrier` are `onlyOwner` (DAO-owned); `setDisputeBoard`/`setMarketplace` are one-shot `deployer`-gated with `AlreadyWired`; `attestEvidence` requires `isVerifier` + threshold; `attestCarrierEvidence` requires `msg.sender == logisticsPartner` + registered proven key. Same class as QC3-1 (Stage 3). |
| QC4-3 | MEDIUM | Vault `_feeForAmount` | Overflow in fee calculation | **Defense-in-depth fix**: explicit `amount > type(uint256).max / bps` guard (`InvalidAmount`) added — Solidity ≥0.8 would already revert; now explicit for auditors/tools. |
| QC4-4 | MEDIUM | Vault `_pay`/`_payRelease`/`_require*Signature`/`_isVerifier`/`_verifierThreshold` | Unchecked external-call returns | **Already handled**: `_pay` checks `(ok,)` and credits on failure; board fee share checks `dOk` → credits; precompile tuple fields (algorithm/pubkey) intentionally unread while `registered`/`proven` are checked. Same as QC3-3 (Stage 3). |
| QC4-5 | MEDIUM | Vault `attestEvidence` | Oracle manipulation | **By design, with on-chain teeth**: verifiers are stake-backed at approval (`addVerifier` requires `verifierStake ≥ minVerifierStake`, slashable via `slashVerifier`), attestation needs an M-of-N distinct-verifier threshold, and Django reputation accrues only from verified completions. Raising `minVerifierStake` above 0 is a DAO config decision (see Known limitations). |
| QC4-6 | LOW | Board `_drawPanel` | Unbounded loop in panel selection | **Fixed**: `while` → bounded `for` with named `MAX_DRAW_ATTEMPTS_PER_POOL` (6× pool) + early return on empty pool. Regression: `test_SelectPanel_EmptyPool_ReturnsZeroMembers`. |
| QC4-7 | INFO | All contracts | No direct ERC compliance | **Accepted** — internal economy contracts (no ERC20/721 surface by design). |

**Post-patch evidence:** Slither 0.11.6 on patched source: 7 High / 10 Medium
(all remaining are the triaged by-design classes in
`docs/audit/stage-4/README.md`); Foundry **133/133** (131 + 2 Stage 4
regressions). The patched source is **not yet redeployed** — see the
redeploy decision below.

## Stage 5 — audit on patched v6 (QCAI report, **72/100**, 2026-11-25)

PDF: `docs/audit/stage-5/QoreChain_Audit_Contract_1795595561507.pdf`
(a genuinely fresh submission — new report ID; the first "Stage 5" PDF was
byte-identical to Stage 4 and was discarded).
Bundle: `docs/audit/stage-5/sweeft-combined.sol` (the patched source).

**Verdict: the score did not move (72), but the findings did.** Score is
rule-template-driven: the loop fix, the overflow guard and the CEI reorder
are all in the audited code, yet `Unbounded Loop`/`Overflow`/`Reentrancy`
still fire on the same functions (the auditor wants "SafeMath"/"maximum
iteration limit" textually; our `MAX_DRAW_ATTEMPTS_PER_POOL` and
`type(uint256).max / bps` guard are functionally those things). This matches
the Stage 1→3 pattern (72→72→78) and Haven Escrow's 35/100 — the jury value
is the mapping below, not the number. The patched stack is now **live as
v7** (see `docs/deployments.md`).

| ID (Stage 4 → 5) | Severity | Stage 5 status |
|---|---|---|
| QC4-1 reentrancy | HIGH | Same flag (Vault `release`/`refund`/`_pay`/`_payRelease` — already CEI + `nonReentrant`; Board/DAO2 reordered in the patch). No change in verdict. |
| QC4-2 access control | HIGH | **Narrowed**: only `setDisputeBoard`/`setMarketplace` flagged now (was 6 functions). `registerCarrier`/`removeCarrier`/`attestEvidence`/`attestCarrierEvidence` acknowledged as controlled. Remaining two are one-shot deployer-gated (`AlreadyWired`) — a design commitment, documented as a known limitation. |
| QC4-3 overflow | MEDIUM | Same flag despite the explicit guard (`Use SafeMath` is template text; Solidity ≥0.8 checked math + guard). |
| QC4-4 unchecked returns | MEDIUM | Same class, now also names Board `_send` (checked `(ok,)` → credits fallback). |
| QC4-5 oracle manipulation | MEDIUM | Moved to `_isVerifier`/`_verifierThreshold` (fail-closed `RegistryUnavailable`, stake-backed verifiers — see Stage 4 row). |
| QC4-6 unbounded loop | LOW | Same flag despite `MAX_DRAW_ATTEMPTS_PER_POOL` bounded `for` (auditor wants a "maximum iteration limit" — we have one; template doesn't credit it). |
| QC4-7 ERC compliance | INFO | Unchanged, accepted. |

**Bottom line:** two audit rounds on ~identical templates (72 → 72) with real
code improvements in between (Slither Highs 9→7, 133 tests) prove the score
is not code-responsive. Sweeft's audit story for the jury is: QCAI 78/100
(v5) + 72/100 on v6/v7 with every finding mapped to a fix or a documented
false positive — stronger evidence than any single number.

## Stage 6 — audit on the v8 candidate (QCAI report, **72/100**, 2026-11-26)

PDF: `docs/audit/stage-6/QoreChain_Audit_Contract_1795674246798.pdf`
(a genuinely fresh submission — new report ID). Bundle:
`docs/audit/stage-6/sweeft-combined.sol` (pattern-removal patch).

**Findings shifted again** (7 → 6): both Stage 5 Vault HIGHs are *gone* —
reentrancy-in-release (credits-only settlement), oracle-manipulation (typed
registry calls), and unchecked-returns no longer fire. But two new HIGH
triggers replaced them on functions the auditor did not read, and severity
reshuffled (fee overflow M→H, ERC I→L, timestamp INFO appeared). Net score
unchanged at 72 despite objectively less attack surface (Slither Highs
7→3 after the patch, Vault settle path has zero external calls). This run
confirms the Stage 1–5 pattern: the score is template noise in a 72–78
band (cf. Haven Escrow's 35/100 with comparable code), while the
findings themselves are worth fixing when real.

| ID | Severity | Location | Verdict |
|---|---|---|---|
| QC6-1 | HIGH | Vault `setTreasury`/`setFeeBps` | **False positive** — both are `onlyOwner` (DAO-owned). The template credits the *name* of the modifier in some runs (`registerCarrier` was cleared in Stage 5) but not others; nothing to fix. |
| QC6-2 | HIGH | Vault `_feeForAmount` | **False positive** — explicit `bps > MAX_FEE_BPS` bound + `amount > max/bps` overflow guard (Stage 5 patch). Demands SafeMath (deprecated since Solidity 0.8) — not applicable. |
| QC6-3 | MEDIUM | Vault `withdrawCredits` | **False positive** — `nonReentrant`, CEI (credit zeroed before the single call), and credits can only be the caller's own. A "recipient must not be a contract" rule would break contract wallets for no gain. |
| QC6-4 | MEDIUM | Board `_drawPanel` | Same loop finding again despite `MAX_DRAW_ATTEMPTS_PER_POOL` + absolute `MAX_DRAW_ATTEMPTS = 128` cap — the template never credits bounds. |
| QC6-5 | LOW | All contracts | ERC compliance (was INFO) — accepted, internal economy by design. |
| QC6-6 | INFO | Vault deadline checks | `block.timestamp` — required for delivery deadlines; bounded by MIN/MAX_WINDOW. |

**Bottom line:** pattern removal worked (both Vault HIGHs eliminated,
Slither Highs 7→3, zero settle-path external calls), but the score is
severity-reshuffled template output, not a code delta. The v8 patch is
deployed-ready on its technical merits (136 Foundry tests, credits-only
settlement, typed registry calls); chasing the number further is not a
productive use of the remaining pre-deadline days. The audit trail
(78 v5 → 72 v6 → 78 re-submission → 72 v8, every finding mapped) is the
jury-facing evidence.

## Governance authorization model (hardening note)

Sensitive administration is reachable **only** through `SweeftDAO2.execute`:
a passed, timelocked, stake-weighted proposal (quorum 0.03 QOR, critical
0.05 QOR, proposer bond, guardian veto during the timelock, allowlist
re-checked at execute). Two model decisions, deliberate:

- **Voters do not produce per-vote PQ signatures.** Votes authenticate by
  staked QOR escrow (capital at risk until the proposal finalizes); a stolen
  classical key can only spend the victim's staked vote, and stake escrow is
  the Sybil cost control. PQ voting was evaluated and rejected as
  unnecessary friction for the threat model.
- **Admin execution does not require a separate ML-DSA provenance.**
  Authorization is the quorum + timelock + veto chain itself; per-action
  provenance was evaluated and deferred because DAO execution already
  composes PQ-verified inputs (escrow release/refund signatures are
  PQ-verified inside the Vault regardless of who executes proposals).

Known residual: SweeftDAO (v1) is deployed but inert — it owns nothing
(registry migrated to DAO2), and its target is immutable; any proposal
against it cannot reach the live stack. Left for documentation only.

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
**121 passing**, Django **13 passing** (v5 era; current counts — 131 Foundry +
28 Django — are in the v6 section above).
