# Sweeft — QCAI Stage 4 (v6) audit workspace

**Scope:** the live v6 stack deployed 2026-11-24 on QoreChain Diana
(see `docs/deployments.md`). The Stage 3 audit (78/100) covers **v5 only**;
v6 has not been QCAI-audited yet. This directory is the submission package.

## Submission (manual step — dashboard sign-in required)

1. Regenerate the bundle if `contracts/src/` changed since (it must stay
   byte-identical to the deployed code):
   ```
   .venv/bin/python tools/bundle_contracts.py stage-4
   ```
2. At <https://dashboard.qorechain.io> open the **Contract Auditor**
   (EVM/Solidity setting — **not** CosmWasm + PQC, which reports a mismatch)
   and paste `sweeft-combined.sol` (6 files, ~105 KB).
3. Save the returned PDF here as `QoreChain_Audit_Contract_<id>.pdf`.
4. Map every finding in `docs/AUDIT.md` (new "Stage 4" section): fixed with
   a regression test, or documented as a false positive with the reason.
5. If a real finding is fixed, it needs a regression test **and** a new
   deployment (v7) — v6 is already live, so do not only edit the source.

## Deployed-code verification (bundle == what's live)

Local `forge build` artifacts vs on-chain bytecode (`cast code`): identical
except for **20-byte immutable slots** (Vault `oracleRegistry`/`deployer`,
Board/Marketplace `vault`) which are substituted at construction — every
diff region is exactly 40 hex chars (one address). `SweeftDAO2` and
`SweeftOracleRegistry` match byte-for-byte. So `sweeft-combined.sol` is
provably the deployed v6 code.

- Registry `0x8f02e5c7A12677B8E264Ec3F1eC01a25E93E9734`
- Vault `0x3F27405766e9c820eCCC650e5b8c48D3AeE6715f`
- Marketplace `0x95ee5565911dC8c99037B9654370438E78678594`
- DisputeBoard `0xbbbED3653Fb3aAD8a4E803ab34B506DfFF4b20a5`
- DAO2 `0x4Db7cC7Bf39c9F1eB93D1727Bc5074284f397b2C`

## Complementary analysis — Slither 0.11.6 on v6

Run: `slither contracts/` (102 detectors). Result: **80 findings** —
9 High, 10 Medium, 43 Low, 18 Informational (report: `slither-v6.txt`).
Every High/Medium is one of four by-design patterns (full triage in
`docs/AUDIT.md`):

| Detector | Where | Why by-design |
|---|---|---|
| `arbitrary-send-eth` (3) | `_send`, `_payRelease`, `_payTreasury` | Recipients are stored addresses only (seller, treasury, raiser, caller claiming own reward); never user-supplied |
| `reentrancy-eth` (6) | `_finalizeAppeal`, `finalize`, `_payRelease` | Every external entry is `nonReentrant` (custom `_lock` modifier) — that guard, not strict CEI, is the protection: the payout calls run while state is still mid-transition, and re-entry reverts on the lock. No state-changing function is reachable without the guard. |
| `reentrancy-no-eth` (1) | `DAO2.execute` | `nonReentrant`; `p.state` is written after the target call, so re-entry into `execute` is blocked by the same lock |
| `divide-before-multiply` (6) | `_payoutFirstRound`, `_finalizeAppeal` | Intentional dust rounding on `perVoter = fee / voters`; total paid never exceeds the bond |
| `unused-return` (3) | `_require*Signature` | `pqcKeyStatus` fields (algorithm/pubkey) intentionally unread; `registered`/`proven` are checked |

CI (`crytic/slither-action`, `fail-on: medium`) excludes exactly these five
detector classes via `slither-args` — all other detectors still block on
Medium+. Excluding in CI (rather than comment-disabling in source) keeps the
audited bundle byte-identical to the deployed code.

## Dependency audit — pip-audit on v6

CI (`pip-audit -r requirements.txt`, blocking) initially failed 2026-11-25:

| Package | Advisory | Status |
|---|---|---|
| `PyNaCl 1.6.0` | PYSEC-2026-1448, PYSEC-2026-3002 | **Fixed** — pinned `PyNaCl>=1.6.2` in `requirements.txt` |
| `ecdsa 0.19.2` | PYSEC-2026-1325 (CVE-2024-23342, Minerva timing) | **No fix exists** — upstream considers side channels out of scope; ignored in CI with `--ignore-vuln` (repo never calls `ecdsa.sign_digest`; all signing is client-side or via `eth_account`) |
