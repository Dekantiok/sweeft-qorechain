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

## Local verification already run (not QCAI)

- Foundry: **189/189** (incl. 6 `SweeftQDayAttacks`, 15 carrier-domain,
  17 verifier-PQ, adversarial + invariant suites)
- Django: **78/78**
- Slither 0.11.6 on `contracts/src/` (11 contracts, 102 detectors,
  74 results):
  - `SweeftVault` alone: **0 High / 0 Medium** (10 results: unused-return
    for algorithmId, events-access, timestamp-by-design, low-level-calls
    in `withdrawCredits` only)
  - Cross-contract: `arbitrary-send-eth` on `SweeftDAO2._payTreasury`
    (treasury is DAO-configured, call is owner/DAO-gated) and
    `SweeftDisputeBoard._send` (payouts to staked resolvers after
    vote-finality; reentrancy-eth flagged on `_finalizeAppeal` —
    state writes after the `_payoutFirstRound` call; triaged in
    `docs/AUDIT.md`, not silent)
  - `reentrancy-eth`/`arbitrary-send` in the Vault money path: **cleared**
    (credits-only settlement makes zero external calls in
    `release`/`refund`/`resolveDispute`)

## Live Diana verification (27 Nov 2026)

- Deployed bytecode length matches recompiled `deployedBytecode` for all
  5 contracts; Registry + DAO2 byte-exact; Vault/Board/Marketplace differ
  only by immutable injection (constructor args in DeployStack/Handover).
- Wiring `eth_call`: all owners = DAO2, `feeBps=200`,
  `MAX_DRAW_ATTEMPTS=128`, verifier `keyVersion=1`, carrier registered.
