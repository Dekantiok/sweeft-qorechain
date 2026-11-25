# Sweeft — QCAI Stage 5 (patched v6) audit workspace

**Scope:** the patched source after the Stage 4 findings (see
`docs/AUDIT.md`). This is a **source-only** patch of the live v6 deployment:
logic fixes are CEI reordering, a bounded loop, and an explicit overflow
guard. **Not yet redeployed** — see `REDEPLOY` below.

## Submission (manual step — dashboard sign-in required)

Done 2026-11-25: fresh audit returned report
`QoreChain_Audit_Contract_1795595561507.pdf` (**72/100**, same 7 findings;
see `docs/AUDIT.md` Stage 5). The earlier identical PDF was a cached
re-run and was discarded.

1. Regenerate if `contracts/src/` changed:
   ```
   .venv/bin/python tools/bundle_contracts.py stage-5
   ```
2. Dashboard **Contract Auditor**, EVM/Solidity setting, paste
   `sweeft-combined.sol`.
3. Save the PDF here as `QoreChain_Audit_Contract_<id>.pdf`.
4. Map findings in `docs/AUDIT.md` Stage 5 section.

## What changed since the Stage 4 bundle (all logic-affecting)

- `SweeftDisputeBoard.finalize` / `_finalizeAppeal`: `state = Final` +
  outcome set **before** `_payoutFirstRound` sends and `vault.resolveDispute`
  (CEI). Verified: Slither `reentrancy-eth` 9→7 locally.
- `SweeftDisputeBoard._drawPanel`: `while` → bounded `for` with
  `MAX_DRAW_ATTEMPTS_PER_POOL`; empty pool returns 0 immediately.
- `SweeftVault._feeForAmount`: explicit overflow guard (`InvalidAmount`).
- `SweeftDAO2.execute`: `state = Executed` before `target.call`, flips to
  `Failed` on revert.

Tests: 133/133 Foundry (2 new regressions), 28/28 Django.

## REDEPLOY — done 2026-11-25

The patched source is now **live as v7** (Vault `0xA575…1c6`; see
`docs/deployments.md`). v6 remains deployed and settleable; all new
trades use v7. The Stage 5 audit was run on the same source (report above),
so audited code == live code.
