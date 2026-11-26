# @sweeft/contracts

Reusable Sweeft contracts for QoreChain Diana: post-quantum escrow vault,
marketplace, oracle verifier registry, staked dispute board (random panels +
real appeal) and stake-weighted DAO.

## Install

```bash
forge install Dekantiok/sweeft-qorechain --lib-paths packages/contracts
```

Then add to your `remappings.txt`:

```
@sweeft/=lib/sweeft-qorechain/packages/contracts/src/
```

Import what you need:

```solidity
import { SweeftVault } from "@sweeft/SweeftVault.sol";
import { SweeftDisputeBoard } from "@sweeft/SweeftDisputeBoard.sol";
```

## Deploy

Copy `contracts/script/DeployV6.s.sol` from the main repo (full wiring:
registry/vault/marketplace/board/DAO, allowlist, DAO ownership handover) or
deploy each contract and hand ownership to your own DAO/governance.

**Build note:** these contracts require `via_ir = true` in the consumer's
`foundry.toml` (see `packages/contracts/foundry.toml`).

## Security note

Testnet only. Sweeft has a documented QCAI audit trail (78/100 on v5,
72/100 on v6/v8 with every finding mapped in `docs/AUDIT.md`) and is **not**
externally audited for production use. Escrow release requires the buyer's
ML-DSA-87 signature verified by QoreChain's `pqcVerify` precompile.
