# Sweeft packages — integration paths for other builders

Three ways to build on Sweeft components without forking the app:

## 1. REST API (easiest)

Read-only JSON over indexed state. No auth, rate-limited, units explicit
(`uqor` native / `wei` EVM lane):

```bash
curl /api/v1/                                    # component + contract index
curl /api/v1/listings/?status=active
curl /api/v1/escrows/?seller=0x…&state=funded
curl /api/v1/escrows/3/                         # + live chain state + proof link
curl /api/v1/disputes/?state=final
curl /api/v1/board/                             # live pool + windows
```

## 2. Foundry contracts (`packages/contracts/`)

```bash
forge install Dekantiok/sweeft-qorechain --lib-paths packages/contracts
```

Add remapping `@sweeft/=lib/sweeft-qorechain/packages/contracts/src/`, require
`via_ir = true`, and import `SweeftVault`, `SweeftDisputeBoard`,
`SweeftOracleRegistry`, `SweeftDAO2`, `SweeftMarketplace`. Deploy with
`contracts/script/DeployV6.s.sol` from the main repo for full wiring.

## 3. Python package (`packages/python/`)

```python
from sweeft import SweeftClient, evaluate_mandate, Mandate

client = SweeftClient("http://127.0.0.1:8001")
print(client.escrow(3))        # indexed + live state
print(client.board())          # resolver pool + windows
print(evaluate_mandate(Mandate(1_000_000, 5_000_000), 500_000))
```

## 4. MCP server (`packages/mcp/`)

Exposes search, escrow/dispute/proposal/board reads and the mandate policy
check as MCP tools for any MCP client (read-only; never signs or moves funds):

```bash
SWEEFT_API_BASE=http://127.0.0.1:8001 python packages/mcp/server.py
```
