# AI review log — independent second-pass checks

The main build was produced with Muse (see `AI_USAGE.md`). This file records a
**separate, adversarial review pass** (distinct session, prompted to break the
design rather than confirm it) and what it caught. Every finding here either
became a test or a doc correction.

## Session 1 (2026-11-19, contracts)

Prompt: list every way the vault v3 can lose funds or let a non-buyer settle.

| Finding | Verdict | Resolution |
|---|---|---|
| Release amount not bound to escrow amount in the signed message | Caught | The message already bound `amount` (v3); the test `test_Release_ReplayRejected` pins the nonce, and `e2e_attack.py` proves tampering reverts. No change needed. |
| Fee charged on the *total* including logistics | Caught (v4) | Fixed: goods-only fee base in `_payRelease` and in `DisputeBoard.resolverReward` (QC mapping in `docs/AUDIT.md`). |
| DAO v1 could be used to reach non-registry contracts | Caught | Fixed: pinning + `setMarketplace` single-shot; DAO2 allowlist for all parameter changes. |
| `resolverReward` computed after pool entry | Caught | `receiveFeeShare` is vault-only; rewards pay from `rewardPool`, never stakes. |
| QoreSign payload drift between Python and Solidity | Caught | Pinned by `SweeftMessageFormat.t.sol` (format tests) and validated **bit-for-bit against the official QoreSign test vectors**. |

## Session 2 (2026-11-21, Django + indexer)

Prompt: break the indexing and wallet login paths.

| Finding | Verdict | Resolution |
|---|---|---|
| Indexer could walk past a block whose event failed to project | Caught | Cursor now retreats to `first_failed_block - 1`; handlers are replay-idempotent (recount instead of increment). |
| Listing metadata displayed without verifying the on-chain hash | Caught | `_fetch_verified_metadata` re-hashes the file; mismatches show a placeholder title. |
| Web3 `ret` field shadowing alignment | Caught | Internal `_eth_*` helpers renamed off the reserved name; CI caught it with a signature lint. |
| QoreX EVM lane cannot sign (official limitation) | Confirmed with docs | Connect dialog detects `signArbitrary` capability; MetaMask is required for EVM actions — documented in the testing guide. |
| MetaMask 4100 on personal_sign | Caught (found by the user) | Now re-requests permission and retries once; clear remediation copy. |

## What the review deliberately did NOT change

- DAO membership is open (one wallet, one vote) — the mitigation is the 20 QOR
  stake gate on the dispute board, documented in T5.
- AI output never enters the settlement path — it only returns UI drafts;
  settlement requires a wallet signature and an on-chain check.
