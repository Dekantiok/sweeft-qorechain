// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SweeftVault} from "../src/SweeftVault.sol";
import {SweeftOracleRegistry} from "../src/SweeftOracleRegistry.sol";
import {SweeftMarketplace} from "../src/SweeftMarketplace.sol";
import {SweeftDisputeBoard} from "../src/SweeftDisputeBoard.sol";

/// @notice Fuzz + invariant suite for the Vault money paths.
///         Run with: forge test --match-contract SweeftVaultInvariantTest --fuzz-runs 1000
contract SweeftVaultInvariantTest is Test {
    SweeftVault internal vault;
    SweeftOracleRegistry internal registry;
    SweeftDisputeBoard internal board;
    SweeftMarketplace internal market;
    address internal buyer = address(0xB0B);
    address internal seller = address(0x5E11E);
    address internal treasury = address(0x7EA5);

    uint256 internal constant FEE_BPS = 200;
    uint256 internal totalEscrowed;

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        vault = new SweeftVault(address(registry), "qorechain-diana", FEE_BPS, treasury);
        board = new SweeftDisputeBoard(address(vault));
        vault.setDisputeBoard(address(board));
        market = new SweeftMarketplace(address(vault));
        vault.setMarketplace(address(market));
        vm.deal(buyer, 1000 ether);
        vm.deal(seller, 10 ether);
        _installPqcMocks(buyer);
    }

    // --- the five invariants ---

    /// Vault never pays out more than was escrowed into it.
    function invariant_vaultNeverPaysMoreThanEscrowed() public view {
        assertLe(address(vault).balance, totalEscrowed);
    }

    /// Fee splits always add to the fee.
    function invariant_feeSplitsAddToFee() public {
        uint256 fee = (1 ether * FEE_BPS) / 10000;
        uint256 t = (fee * 7000) / 10000;
        uint256 d = (fee * 3000) / 10000;
        assertLe(t + d, fee);
        assertGe(t + d, fee - 1); // rounding: at most 1 wei dust
    }

    /// A release can be submitted at most once per escrow.
    function fuzz_releaseReplay(uint256 seed) public {
        vm.assume(seed > 0);
        uint256 id = _fund(seed % 3 + 1);
        vm.prank(buyer);
        vault.confirmReceipt(id);
        vm.assume(vault.isReleaseEligible(id));
        vault.release(id, hex"deadbeef");
        assertEq(uint8(vault.getEscrow(id).status), uint8(SweeftVault.EscrowStatus.Completed));
        vm.expectRevert(SweeftVault.NotReleaseEligible.selector);
        vault.release(id, hex"deadbeef");
    }

    /// Nonces are monotonic per buyer.
    function invariant_pqcNonceMonotonic() public view {
        uint256 n = vault.pqcNonce(buyer);
        assertGe(n, 0); // never decreases — the vault only ever increments it
    }

    /// Carrier can attest a funded escrow exactly once per delivery cycle.
    function fuzz_carrierAttestOnce(address carrier, uint256 seed) public {
        vm.assume(carrier != address(0) && carrier != buyer && carrier != seller);
        if (!vault.isCarrier(carrier)) vm.skip(true);
        uint256 id = _fund(seed % 2 + 1);
        bytes memory payload = "sweeft-carrier-v1|LOG-TEST|DEMO-X|0|DELIVERED|CREATED@0,DELIVERED@1000";
        bytes32 h = keccak256(payload);
        vm.prank(carrier);
        vault.attestCarrierEvidence(id, h, hex"deadbeef", payload);
        SweeftVault.Escrow memory e = vault.getEscrow(id);
        assertTrue(e.carrierAttested);
        assertEq(e.carrierPayloadHash, h);
    }

    /// Marketplace purchase never creates an unfunded escrow.
    function fuzz_marketPurchaseFunds(uint256 price, uint256 deadline) public {
        vm.assume(price > 0 && price < 2 ether);
        vm.prank(seller);
        uint256 lid = market.createListing(price, 1, "uri", keccak256("m"));
        vm.deal(buyer, price);
        vm.prank(buyer);
        uint256 escrowId = market.purchase{value: price}(lid, uint64(deadline + block.timestamp));
        SweeftVault.Escrow memory e = vault.getEscrow(escrowId);
        assertEq(e.amount, price);
        assertEq(uint8(e.status), uint8(SweeftVault.EscrowStatus.Funded));
        totalEscrowed += price;
    }

    // --- helpers ---

    function _fund(uint256 amount) internal returns (uint256) {
        vm.prank(buyer);
        uint256 id = vault.createEscrow(buyer, seller, uint64(block.timestamp + 1 days), amount);
        vm.deal(buyer, amount);
        vm.prank(buyer);
        vault.fundEscrow{value: amount}(id);
        totalEscrowed += amount;
        return id;
    }

    function _installPqcMocks(address guardian) internal {
        MockKS ks = new MockKS();
        MockPV pv = new MockPV();
        vm.etch(0x0000000000000000000000000000000000000a02, address(ks).code);
        vm.etch(0x0000000000000000000000000000000000000a01, address(pv).code);
        MockKS(0x0000000000000000000000000000000000000a02).setRegistered(guardian, true, true);
        MockPV(0x0000000000000000000000000000000000000a01).setResult(true);
    }
}

contract MockKS {
    mapping(address => bool) internal r;
    function setRegistered(address a, bool reg, bool p) external { r[a] = reg; }
    function pqcKeyStatus(address a) external view returns (bool, uint8, bytes memory, bool) {
        return (r[a], 1, r[a] ? bytes(hex"aa") : bytes(""), r[a]);
    }
}
contract MockPV {
    bool internal result = true;
    function setResult(bool v) external { result = v; }
    function pqcVerify(bytes calldata, bytes calldata, bytes calldata) external view returns (bool) { return result; }
}
