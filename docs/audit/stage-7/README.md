# Sweeft — QCAI Stage 7 (v9) audit workspace

**Scope:** v9 hardened stack (carrier domain separation v2, PQ verifier
attestations with relayer submission, committed future-block dispute seeds,
credits-only settlement, typed oracle reads, AI mandate hardening).
**Status: NOT YET QCAI-AUDITED — no score claimed.**

Latest OBTAINED QCAI score remains **72/100 (Stage 6, on v8 source)**.
Stage 7 is bundle-ready; the dashboard submission is a manual step
(sign-in required) and has not been run at the time of writing.

## Bundle (generated 27 Nov 2026)

- `sweeft-combined.sol` — 6 contracts, 124,142 bytes
  (`tools/bundle_contracts.py stage-7`)
- `sweeft-contracts-7.tar.gz` — sources for dashboard upload

## Submission (manual)

1. Dashboard Contract Auditor, **EVM/Solidity** (NOT CosmWasm+PQC).
2. Fresh audit, paste `sweeft-combined.sol`.
3. Verify new report ID + fresh timestamp (cached re-runs return old PDFs).
4. Save PDF here; map findings in `docs/AUDIT.md` with regression tests.

## Local audit run (27 Nov 2026, HEAD `41177ee` — not QCAI)

- Bundle regenerated from HEAD (`sha256 0c5a37c3…`, 124,142 bytes).
- Foundry: **189/189** (incl. 6 `SweeftQDayAttacks`, 15 carrier-domain,
  17 verifier-PQ, adversarial + invariant suites)
- Django: **81/81**
- Slither 0.11.6 on `contracts/src/` (11 contracts, 102 detectors,
  74 results: **3 High / 10 Medium** / 46 Low / 15 Info) — full triage
  in `FINDINGS.md` (raw: `slither-v9.txt`, JSON: `slither-v9.json`):
  - `SweeftVault` alone: **0 High / 0 Medium** (10 results: unused-return
    for algorithmId, events-access, timestamp-by-design, low-level-calls
    in `withdrawCredits` only)
  - 3 High = 2 design-intentional sends (`_payTreasury`, `_send`) +
    1 false-positive `reentrancy-eth` (CEI: state=Final before call)
  - 10 Medium = 6 accepted payout-rounding + 1 false-positive
    `reentrancy-no-eth` (DAO `execute` is `nonReentrant`, state-first) +
    3 info-level `unused-return` (algorithmId checked for verifiers only;
    `pqcVerify` itself enforces ML-DSA-87, so not exploitable)
  - `reentrancy-eth`/`arbitrary-send` in the Vault money path: **cleared**
    (credits-only settlement makes zero external calls in
    `release`/`refund`/`resolveDispute`)

## Live Diana verification (27 Nov 2026)

- Deployed bytecode length matches recompiled `deployedBytecode` for all
  5 contracts; Registry + DAO2 byte-exact; Vault/Board/Marketplace differ
  only by immutable injection (constructor args in DeployStack/Handover).
- Wiring `eth_call`: all owners = DAO2, `feeBps=200`,
  `MAX_DRAW_ATTEMPTS=128`, verifier `keyVersion=1`, carrier registered.
