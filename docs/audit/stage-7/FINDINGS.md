# Stage 7 (v9) — Local Audit Findings (Slither 0.11.6, 27 Nov 2026)

> This is the **local static-analysis pass** (companion to the dashboard
> run). QCAI Stage 7 (78/100, HIGH, 27 Nov 2026) is in `docs/AUDIT.md`;
> the PDF is `QoreChain_Audit_Contract_1795777556004.pdf` in this folder.

- Bundle: `sweeft-combined.sol` (124,142 bytes, sha256 `0c5a37c3…`),
  regenerated from HEAD at audit time.
- Scope: `contracts/src/` — 6 contracts, 11 contracts analyzed (incl.
  interfaces), 102 detectors, **74 results**: 3 High, 10 Medium, 46 Low,
  15 Informational (raw: `slither-v9.txt`, JSON: `slither-v9.json`).
- Tests: Foundry **189/189**, Django **81/81** at audit time.

## High (3) — all triaged, none is a fund-loss path

| Detector | Location | Verdict |
|---|---|---|
| `arbitrary-send-eth` | `SweeftDisputeBoard.sol:758` `_send()` | **By design.** Pays resolvers / raiser / appellant — recipients are fixed dispute roles, not caller-supplied. Returns bool; on failure funds fall back to `rewardPool` (never bricks settlement). |
| `arbitrary-send-eth` | `SweeftDAO2.sol:410` `_payTreasury()` | **By design.** `treasury` is DAO-governed storage (`setTreasury`, owner-gated), not a call argument. On failure credits `treasuryCredits` for later pull. |
| `reentrancy-eth` | `SweeftDisputeBoard.sol:594` `_finalizeAppeal` | **False positive (CEI already applied).** `d.state = Final` is written **before** `_payoutFirstRound` (line ~621); the post-call write Slither flags (`appealRewardPerVoter`) is a new accounting value, not a reopened gate. Re-entering sees `Final` and cannot re-run settlement. |

Vault money path (`release`/`refund`/`resolveDispute`): **zero external
calls** (credits-only) — no Slither reentrancy or arbitrary-send there.

## Medium (10)

| Detector | Location | Verdict |
|---|---|---|
| `divide-before-multiply` ×6 | `SweeftDisputeBoard.sol:656,594` payouts | **Accepted rounding.** `(bond * BPS) / 10_000` multiplies first; `fee / voters` floors per-voter pay and the dust remainder goes to raiser/treasury via `_send`→`rewardPool` fallback. Max loss < voters wei per dispute. No fix (changing it moves dust, not money). |
| `reentrancy-no-eth` | `SweeftDAO2.sol:307` `execute` | **False positive.** `nonReentrant` + `p.state = Executed` **before** `p.target.call` (line ~327); re-entry sees a closed proposal. |
| `unused-return` ×3 | `SweeftVault.sol:685,758,942` | **Info-level consistency gap.** `algorithmId` is ignored for buyer/carrier keys but enforced `== 1` (ML-DSA-87) for verifiers (`SweeftVault.sol:835`). Not exploitable — `pqcVerify` itself verifies ML-DSA-87 and rejects other algorithms — but a future verifier-style check should be unified. No behavior change made in this audit (would alter the live v9 bytecode for zero security gain). |

## Low / Informational (61)

`timestamp` (deadline/expiry comparisons — by design; no `block.timestamp`
as randomness anywhere in v9), `unused-state` (`CHOICE_ABSTAIN` in
deprecated `SweeftDAO` v1 — inert, owns nothing), `events-access`,
`low-level-calls` (`withdrawCredits` only — CEI zero-before-call),
`shadowing-local`, `assembly` (none), `cyclomatic-complexity` in
`SweeftDisputeBoard` payout paths (bounded loops, `MAX_DRAW_ATTEMPTS=128`).
All carried from prior stages in `docs/AUDIT.md`; no new Low was
introduced by v9 changes.

## Regression coverage for every verdict above

- Credits-only / no-reentrancy: `SweeftVault.t.sol` settlement suites,
  `SweeftVault.invariant.t.sol` (credits ≤ escrowed).
- DAO execute CEI + allowlist re-check: `SweeftDAO2.t.sol`,
  `SweeftGovernance.t.sol`.
- Dispute payout rounding: `SweeftDisputeBoard.t.sol` (bond/reward cases).
- Q-Day attacks (live + local): `tools/qday_attack_demo.py`,
  `SweeftQDayAttacks.t.sol` (6/6).

## What the dashboard run still needs (manual)

1. `https://dashboard.qorechain.io` → Contract Auditor → **EVM/Solidity**.
2. Paste `sweeft-combined.sol` (or upload `sweeft-contracts-7.tar.gz`).
3. Confirm the PDF has a **new report ID + fresh timestamp**.
4. Save as `QoreChain_Audit_Contract_<id>.pdf` in this folder and map
   findings into `docs/AUDIT.md` with regression tests.
