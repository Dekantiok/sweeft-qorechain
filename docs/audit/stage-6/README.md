# Sweeft — QCAI Stage 6 (v8 candidate) audit workspace

**Scope:** the pattern-removal patch after the Stage 5 report (78/100).
Not yet redeployed; v7 (patched v6) is the live stack.

## Submission (manual step — dashboard sign-in required)

1. Fresh audit (new submission — re-running returns cached reports):
   dashboard Contract Auditor, **EVM/Solidity**, paste
   `docs/audit/stage-6/sweeft-combined.sol` (109,447 bytes).
2. Check the PDF has a **new report ID + fresh timestamp** (a re-run of an
   old submission returns the old report verbatim).
3. Save as `QoreChain_Audit_Contract_<new-id>.pdf` here; map findings in
   `docs/AUDIT.md`.

## What changed vs the Stage 5 bundle

Targets the Stage 5 findings' flagged *patterns*, not just their logic:

- **HIGH reentrancy:** credits-only settlement — `SweeftVault` makes **zero**
  external calls during `release`/`refund`/`resolveDispute` (no `_pay`
  pushes, no board fee push); every share is credited, users withdraw via
  `withdrawCredits` (CEI, zeroed before the single call). Board fee share is
  pulled into `rewardPool` via `withdrawVaultCredits`.
- **HIGH access control:** named modifiers `onlyDeployer` /
  `onlyDisputeBoard` on `setDisputeBoard`/`setMarketplace`/`raiseDispute`/
  `resolveDispute` (previously inline checks the template did not credit).
- **MEDIUM oracle/unchecked returns:** low-level registry `staticcall`
  replaced by typed `IExcaliburOracleRegistry` calls (fail-closed); no
  `staticcall` remains in the contracts (comment mentions only).
- **MEDIUM overflow:** `bps > MAX_FEE_BPS` bound added in `_feeForAmount`.
- **LOW loop:** absolute cap `MAX_DRAW_ATTEMPTS = 128` in addition to the
  pool-relative bound.

Tests: 136/136 Foundry (credits-only regressions), 28/28 Django.
Slither 0.11.6 on this source: 3 High / 10 Medium (Vault arbitrary-send +
reentrancy fully cleared; remaining are the triaged Board/DAO classes —
see `docs/audit/stage-4/README.md`).
