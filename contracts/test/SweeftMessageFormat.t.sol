// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SweeftVault } from "../src/SweeftVault.sol";

/// @notice Harness exposing the internal message builders for format tests.
contract VaultHarness is SweeftVault {
    constructor(address registry, string memory chainId)
        SweeftVault(registry, chainId, 200, address(0x7EA5))
    {}

    function releaseMessage(uint256 id, address buyer, address recipient, uint256 amount, uint256 nonce)
        external
        view
        returns (bytes memory)
    {
        return _releaseMessage(id, buyer, recipient, amount, nonce);
    }

    function refundMessage(uint256 id, address buyer, address recipient, uint256 amount, uint256 nonce)
        external
        view
        returns (bytes memory)
    {
        return _refundMessage(id, buyer, recipient, amount, nonce);
    }

    function uintToString(uint256 value) external pure returns (string memory) {
        return _uintToString(value);
    }

    function toHexString(address account) external pure returns (string memory) {
        return _toHexString(account);
    }
}

/// @dev The release/refund message format is a cross-implementation contract:
///      the Python tools and the QoreX wallet build the same bytes. These tests
///      pin the format so a contract change cannot silently break signing.
contract SweeftMessageFormatTest is Test {
    VaultHarness internal vault;

    function setUp() public {
        vault = new VaultHarness(address(0x1), "qorechain-diana");
    }

    function test_UintToString() public {
        assertEq(vault.uintToString(0), "0");
        assertEq(vault.uintToString(7), "7");
        assertEq(vault.uintToString(42), "42");
        assertEq(vault.uintToString(1_000_000), "1000000");
        assertEq(vault.uintToString(100_000_000_000_000_000), "100000000000000000");
        assertEq(vault.uintToString(2 ** 255), "57896044618658097711785492504343953926634992332820282019728792003956564819968");
        assertEq(vault.uintToString(type(uint256).max), "115792089237316195423570985008687907853269984665640564039457584007913129639935");
    }

    function test_ToHexString() public {
        assertEq(vault.toHexString(address(0)), "0x0000000000000000000000000000000000000000");
        assertEq(vault.toHexString(address(1)), "0x0000000000000000000000000000000000000001");
        assertEq(vault.toHexString(address(0xcaF82Bd8EBd87634eFb610aE63a7bCf1CE3ac87D)), "0xcaf82bd8ebd87634efb610ae63a7bcf1ce3ac87d");
        assertEq(vault.toHexString(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF)), "0xffffffffffffffffffffffffffffffffffffffff");
    }

    function test_ReleaseMessageFormat() public {
        bytes memory message = vault.releaseMessage(
            3,
            address(0xcaF82Bd8EBd87634eFb610aE63a7bCf1CE3ac87D),
            address(0x8508BF11b1C2D225c1727F4c7b75B5e3d3C84cB0),
            100_000_000_000_000_000,
            2
        );
        assertEq(
            string(message),
            string.concat(
                "sweeft-release-v1|vault=",
                vault.toHexString(address(vault)),
                "|escrow=3",
                "|buyer=0xcaf82bd8ebd87634efb610ae63a7bcf1ce3ac87d",
                "|recipient=0x8508bf11b1c2d225c1727f4c7b75b5e3d3c84cb0",
                "|amount=100000000000000000",
                "|nonce=2"
            )
        );
    }

    function test_RefundMessageFormat() public {
        bytes memory message = vault.refundMessage(
            7,
            address(0xcaF82Bd8EBd87634eFb610aE63a7bCf1CE3ac87D),
            address(0xcaF82Bd8EBd87634eFb610aE63a7bCf1CE3ac87D),
            5,
            0
        );
        assertEq(
            string(message),
            string.concat(
                "sweeft-refund-v1|vault=",
                vault.toHexString(address(vault)),
                "|escrow=7",
                "|buyer=0xcaf82bd8ebd87634efb610ae63a7bcf1ce3ac87d",
                "|recipient=0xcaf82bd8ebd87634efb610ae63a7bcf1ce3ac87d",
                "|amount=5",
                "|nonce=0"
            )
        );
    }

    function test_CosmosChainIdStored() public {
        assertEq(vault.cosmosChainId(), "qorechain-diana");
    }

    /// @notice Carrier v2 format is pinned byte-for-byte (Phase 2), matching
    ///         apps/logistics/carriers.py::canonical_carrier_attestation.
    function test_CarrierMessageFormatV2() public {
        bytes memory message = vault.buildCarrierMessage(
            address(0xCA99),
            2,
            "DEMO-123",
            "DELIVERED",
            bytes32(uint256(0x1234)),
            1_000,
            1_000 + 7 days,
            0
        );
        // provider is empty here (no carrier registered in the harness); the
        // expected bytes below were produced by the Python builder with the
        // same inputs (evidence=0x…1234, expires=605800).
        assertEq(
            string(message),
            string.concat(
                "sweeft-carrier-v2|chain=qorechain-diana|vault=",
                vault.toHexString(address(vault)),
                "|carrier=0x000000000000000000000000000000000000ca99|provider=|escrow=2",
                "|trackingHash=0x859694e94e4d6e0a88de8752683e9552ea129abcb3b266ffb1548e2fff079f2d",
                "|status=DELIVERED",
                "|evidence=0x0000000000000000000000000000000000000000000000000000000000001234",
                "|issued=1000|expires=605800|nonce=0"
            )
        );
    }
}
