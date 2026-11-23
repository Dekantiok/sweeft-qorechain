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

- **T1 Leaked classical key.** Steal an EVM key → still cannot release/refund (needs buyer ML-DSA-87) or attest (needs registry membership). Proven by `e2e_attack.py` on testnet (wrong-key + tampered-amount both revert).
- **T2 Forged carrier scans.** Carrier payload signature checked on-chain against the key registered for that carrier; unregistered carriers cannot attest (`NotCarrier`, `CarrierKeyNotRegistered`).
- **T3 Replay.** Release/refund signatures are bound to a per-buyer nonce; carrier payloads bind escrowId + payload hash.
- **T4 Stolen seller key.** Seller cannot self-release: release pays the stored `seller` address with a buyer PQ signature.
- **T5 Dispute abuse.** Board = first 3 stakers ≥ 20 QOR, parties and the attesting verifier excluded, 2-of-3 majority; stakes lock while serving; rewards come from the fee pool, never from stakes.
- **T6 DAO takeover.** DAO2 calls are allowlisted to registry/vault/board; a passed proposal cannot reach arbitrary contracts.
- **T7 Window expiry / fund lock.** Release eligibility is derived (buyer confirm OR delivery/attestation + deadline); dispute path is the escape hatch; refund works after the deadline unless attested.
- **T8 Amount integrity.** `createEscrow` requires exact deposit; marketplace forwards the listing price; logistics share is a sub-allocation of the total, fee is on goods only.

## Stage 1 — findings (QCAI report, 72/100, MEDIUM, 2026-11-23)

PDF: `docs/audit/stage-1/QoreChain_Audit_Contract_1795443924061.pdf`

| ID | Severity | Location | Finding | Status | Fix / justification | Regression test |
|---|---|---|---|---|---|---|
| QC-1 | HIGH | `SweeftDisputeBoard.sol:340` | Missing Access Control on Critical Functions | **False positive** — flagged line is the `votesForRefund` field inside the `getDispute()` *view* (line ~340). Every state-changing board function is `onlyOwner`, party-checked, or members-only: `setMinStake`/`setUnstakeCooldown`/`setVotingPeriod`/`transferOwnership` (`onlyOwner`), `resolveExpired` (`onlyOwner`), `openDispute` (buyer/seller), `joinDispute` (staker, not a party), `castVote` (member-only), `claimReward` (voter-only). No owner path is missing. | — |
| QC-2 | MEDIUM | `SweeftDAO.sol:44`, `SweeftDAO2.sol:44` | Potential overflow in vote counting (uint64) | **Fixed** — vote counters widened to `uint256` in both DAOs; one vote per wallet makes overflow impossible regardless | `test_OneVotePerWallet`, `test_VoteCast` suites |
| QC-3 | MEDIUM | `SweeftDAO2.sol:127` | Unchecked return values in external calls | **Fixed** — `execute()` now bubbles the target's revert reason instead of masking it (was checked, now also informative) | `test_FullFlow_ApproveVerifier`, `test_ExecuteBubblesReason` (new) |
| QC-4 | LOW | `SweeftDisputeBoard.sol:362` | Unbounded loop in dispute settlement | **Fixed** — `MAX_BOARD_SIZE = 3` constant; loop is explicitly bounded and join gate references it | `test_Join_MaxThree` |
| QC-5 | INFO | `SweeftDisputeBoard.sol:290` | Front-running in board joining | **Acknowledged risk** — first-come-first-served is the agreed rule; mitigations are the 20 QOR stake lock (economic cost to Sybil/frontrun), party/verifier exclusion, and one vote per resolver. Documented in threat model T5. | — |

## Stage 2 — re-audit

After the Stage 1 report lands and the table above is updated with the real
finding IDs, re-audit with the same EVM/Solidity setting. Keep both PDFs in
`docs/audit/stage-1/` and `docs/audit/stage-2/` and link them from the README.
