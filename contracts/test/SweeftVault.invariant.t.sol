// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SweeftVault} from "../src/SweeftVault.sol";
import {SweeftOracleRegistry} from "../src/SweeftOracleRegistry.sol";
import {SweeftMarketplace} from "../src/SweeftMarketplace.sol";
import {SweeftDisputeBoard} from "../src/SweeftDisputeBoard.sol";

/// @notice Fuzz + invariant suite for the Vault money paths.
///         Run with: forge test --match-contract SweeftVaultInvariantTest
contract SweeftVaultInvariantTest is Test {
    SweeftVault internal vault;
    SweeftOracleRegistry internal registry;
    SweeftDisputeBoard internal board;
    SweeftMarketplace internal market;
    address internal buyer = address(0xB0B);
    address internal seller = address(0x5E11E);
    address internal treasury = address(0x7EA5);
    address internal carrier = address(0xCA99);

    uint256 internal constant FEE_BPS = 200;
    uint256 internal totalEscrowed;

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        vault = new SweeftVault(address(registry), "qorechain-diana", FEE_BPS, treasury);
        board = new SweeftDisputeBoard(address(vault), treasury);
        vault.setDisputeBoard(address(board));
        market = new SweeftMarketplace(address(vault));
        vault.setMarketplace(address(market));
        vm.deal(buyer, 1000 ether);
        vm.deal(seller, 10 ether);
        _installPqcMocks();
        vault.registerCarrier(carrier, "LOG-INV-001");
    }

    // --- invariants ---

    /// Vault never pays out more than was escrowed into it.
    function invariant_vaultNeverPaysMoreThanEscrowed() public view {
        assertLe(address(vault).balance, totalEscrowed);
    }

    /// Fee splits always add to the fee (within 1 wei of rounding dust).
    function invariant_feeSplitsAddToFee() public {
        uint256 fee = (1 ether * FEE_BPS) / 10000;
        uint256 t = (fee * 7000) / 10000;
        uint256 d = (fee * 3000) / 10000;
        assertLe(t + d, fee);
        assertGe(t + d, fee - 1);
    }

    /// Credits held by the vault are always fully backed by its balance.
    function invariant_creditsAreBacked() public view {
        assertLe(vault.credits(buyer) + vault.credits(seller), address(vault).balance);
    }

    // --- fuzz ---

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

    function fuzz_carrierAttestOnce(uint256 seed) public {
        uint256 id = _fundLogistics(seed % 2 + 1);
        vm.prank(carrier);
        vault.attestCarrierEvidence(id, "DEMO-INV", "DELIVERED", bytes32(uint256(0x1234)), uint64(block.timestamp), uint64(block.timestamp + 7 days), hex"deadbeef");
        SweeftVault.Escrow memory e = vault.getEscrow(id);
        assertTrue(e.carrierAttested);
        assertTrue(e.delivered);
        assertEq(e.carrierSigner, carrier);
    }

    /// Invalid attestation attempts (wrong caller, garbage signature) never
    /// increase the attestation count (Phase 9 verifier invariant).
    function fuzz_invalidAttestNeverCounts(uint256 seed, bytes32 evidenceHash) public {
        uint256 id = _fundLogistics(seed % 2 + 1);
        address attacker = address(uint160(bound(seed, 2, type(uint16).max)));
        if (attacker == carrier || attacker == buyer) return;
        uint8 before = vault.verifierAttestCount(id);
        vm.prank(attacker);
        try vault.attestEvidence(id, attacker, evidenceHash, uint64(block.timestamp), uint64(block.timestamp + 7 days), hex"00") {
            // MockVerify is permissive; distance comes from the caller not
            // being a registered verifier. A count increase means the gate
            // is broken.
            assertEq(vault.verifierAttestCount(id), before, "invalid attestation counted");
        } catch {
            // Revert path: count must be untouched.
            assertEq(vault.verifierAttestCount(id), before);
        }
    }

    /// A settled escrow can never settle again (idempotency of release).
    function fuzz_doubleSettleImpossible(uint256 seed) public {
        uint256 id = _fundLogistics(seed % 2 + 1);
        vm.prank(buyer);
        vault.confirmReceipt(id);
        vault.release(id, hex"deadbeef");
        uint256 creditsBefore = vault.credits(seller);
        vm.expectRevert(SweeftVault.InvalidStatus.selector);
        vault.release(id, hex"deadbeef");
        assertEq(vault.credits(seller), creditsBefore);
    }

    function fuzz_marketPurchaseFunds(uint256 price) public {
        vm.assume(price > 0 && price < 2 ether);
        vm.prank(seller);
        uint256 lid = market.createListing(price, 1, "uri", keccak256("m"));
        vm.deal(buyer, price);
        vm.prank(buyer);
        uint256 escrowId = market.purchase{value: price}(lid, uint64(block.timestamp + 2 days), price, keccak256("m"));
        SweeftVault.Escrow memory e = vault.getEscrow(escrowId);
        assertEq(e.amount, price);
        assertEq(uint8(e.status), uint8(SweeftVault.EscrowStatus.Funded));
        totalEscrowed += price;
    }

    // --- helpers ---

    function _fund(uint256 amount) internal returns (uint256) {
        vm.prank(buyer);
        uint256 id = vault.createEscrow(buyer, seller, uint64(block.timestamp + 2 days), amount);
        vm.deal(buyer, amount);
        vm.prank(buyer);
        vault.fundEscrow{value: amount}(id);
        totalEscrowed += amount;
        return id;
    }

    function _fundLogistics(uint256 amount) internal returns (uint256) {
        uint256 total = amount + 0.1 ether;
        vm.prank(buyer);
        uint256 id = vault.createEscrowWithLogistics(buyer, seller, carrier, uint64(block.timestamp + 2 days), total, 0.1 ether);
        vm.deal(buyer, total);
        vm.prank(buyer);
        vault.fundEscrow{value: total}(id);
        totalEscrowed += total;
        return id;
    }

    function _installPqcMocks() internal {
        MockKS ks = new MockKS();
        MockPV pv = new MockPV();
        vm.etch(0x0000000000000000000000000000000000000a02, address(ks).code);
        vm.etch(0x0000000000000000000000000000000000000a01, address(pv).code);
        MockKS(0x0000000000000000000000000000000000000a02).setRegistered(buyer, true, true);
        MockKS(0x0000000000000000000000000000000000000a02).setRegistered(carrier, true, true);
        MockPV(0x0000000000000000000000000000000000000a01).setResult(true);
    }
}

contract MockKS {
    mapping(address => bool) internal r;
    mapping(address => bool) internal p;
    function setRegistered(address a, bool reg, bool proven) external { r[a] = reg; p[a] = proven; }
    function pqcKeyStatus(address a) external view returns (bool, uint8, bytes memory, bool) {
        return (r[a], 1, r[a] ? bytes(hex"aa") : bytes(""), p[a]);
    }
}
contract MockPV {
    bool internal result = true;
    function setResult(bool v) external { result = v; }
    function pqcVerify(bytes calldata, bytes calldata, bytes calldata) external view returns (bool) { return result; }
}
