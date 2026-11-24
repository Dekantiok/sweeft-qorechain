#!/usr/bin/env python3
"""Read-only wiring check for a deployed Sweeft stack (v5)."""
import json
import sys

import httpx

RPC = "https://evm-testnet.qore.host"
VAULT = "0x979d3d6688600FdeE7ce61E978bD8398d5e1B007"
REG = "0x07712806b83Fac288F2F61F892Cd26f8778b94a2"
DAO = "0x23DC3D2014C62095B8b5A23C7552301Cf829BdaF"
BOARD = "0x1aA3156cB862e3569FA12dC8ab5145EfB2D15Fb9"


def call(to, selector):
    r = httpx.post(
        RPC,
        json={"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [{"to": to, "data": selector}, "latest"]},
        timeout=20,
    )
    res = r.json().get("result", "")
    if len(res) >= 42:
        return "0x" + res[-40:]
    return res


# selectors
SEL = {
    "oracleRegistry()": "0x4bb93ab1",
    "marketplace()": "0xabc8c7af",
    "disputeBoard()": "0x9f67b1c4",
    "owner()": "0x8da5cb5b",
    "threshold()": "0x42cde4e8",
    "feeBps()": "0x24a9d853",
    "quorum()": "0x7e7b8b3a",
    "MIN_VOTING_PERIOD()": "0x215809ca",
    "TIMELOCK()": "0x7aadef8b",
    "PROPOSER_BOND()": "0x1ef7a1f7",
    "minStakeFor(uint256)": "0x6b5f0a23",
}

print("vault.oracleRegistry():", call(VAULT, SEL["oracleRegistry()"]))
print("vault.marketplace():   ", call(VAULT, SEL["marketplace()"]))
print("vault.disputeBoard():  ", call(VAULT, SEL["disputeBoard()"]))
print("vault.owner():         ", call(VAULT, SEL["owner()"]))
print("vault.feeBps():        ", call(VAULT, SEL["feeBps()"]))
print("registry.owner():      ", call(REG, SEL["owner()"]))
print("registry.threshold():  ", call(REG, SEL["threshold()"]))
print("dao.owner():           ", call(DAO, SEL["owner()"]))
print("board.owner():         ", call(BOARD, SEL["owner()"]))
print("dao.MIN_VOTING_PERIOD():", call(DAO, SEL["MIN_VOTING_PERIOD()"]))
print("dao.TIMELOCK():        ", call(DAO, SEL["TIMELOCK()"]))
print("dao.PROPOSER_BOND():   ", call(DAO, SEL["PROPOSER_BOND()"]))
print("board.minStakeFor(1e17):", call(BOARD, SEL["minStakeFor(uint256)"] + "0" * 63 + "1" + "0" * 17))
