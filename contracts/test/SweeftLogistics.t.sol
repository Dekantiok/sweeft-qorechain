// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SweeftVault} from "../src/SweeftVault.sol";
import {SweeftDisputeBoard} from "../src/SweeftDisputeBoard.sol";
import {SweeftOracleRegistry} from "../src/SweeftOracleRegistry.sol";
import {SweeftMarketplace} from "../src/SweeftMarketplace.sol";

// Mocks etched at QoreChain precompile addresses
contract MockKeyStatus {
    mapping(address => bool) internal registered;
    mapping(address => bool) internal proven;
    function setRegistered(address a, bool r, bool p) external {
        registered[a] = r;
        proven[a] = p;
    }
    function pqcKeyStatus(address a) external view returns (bool, uint8, bytes memory, bool) {
        return (registered[a], 1, registered[a] ? bytes(hex"aa") : bytes(""), proven[a]);
    }
}
contract MockVerify {
    bool internal result = true;
    mapping(string => bool) internal wrongFor;
    mapping(bytes => bool) internal wrongPayload;
    function setResult(bool r) external { result = r; }
    function pqcVerify(bytes calldata, bytes calldata m, bytes calldata) external view returns (bool) { return result; }
}

contract SweeftLogisticsTest is Test {
    SweeftVault internal vault;
    SweeftDisputeBoard internal board;
    SweeftMarketplace internal market;
    SweeftOracleRegistry internal registry;
    MockKeyStatus internal ks;
    MockVerify internal pv;

    address internal buyer = address(0xB0B);
    address internal seller = address(0x5E11E);
    address internal carrier = address(0xCA99);
    address internal treasury = address(0x7EA5);

    uint256 internal constant FEE_BPS = 200;

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        vault = new SweeftVault(address(registry), "qorechain-diana", FEE_BPS, treasury);
        board = new SweeftDisputeBoard(address(vault));
        vault.setDisputeBoard(address(board));
        market = new SweeftMarketplace(address(vault));
        vault.setMarketplace(address(market));

        ks = new MockKeyStatus();
        pv = new MockVerify();
        vm.etch(0x0000000000000000000000000000000000000a02, address(ks).code);
        vm.etch(0x0000000000000000000000000000000000000a01, address(pv).code);
        MockKeyStatus(0x0000000000000000000000000000000000000a02).setRegistered(buyer, true, true);
        MockKeyStatus(0x0000000000000000000000000000000000000a02).setRegistered(carrier, true, true);
        MockVerify(0x0000000000000000000000000000000000000a01).setResult(true);

        vault.registerCarrier(carrier, "LOG-DEMO-001");
    }

    function test_registerCarrier_ownerOnly() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(SweeftVault.NotOwner.selector);
        vault.registerCarrier(address(0xBEEF), "LOG-X");
    }

    function test_attestCarrierEvidence_valid() public {
        vm.prank(buyer);
        uint256 id = vault.createEscrowWithLogistics(buyer, seller, carrier, uint64(block.timestamp + 7 days), 1 ether, 0.1 ether);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vault.fundEscrow{value: 1 ether}(id);

        bytes memory payload = "sweaft-carrier-v1|LOG-DEMO-001|DEMO-123|1|DELIVERED|CREATED@0,DELIVERED@1000";
        bytes32 h = keccak256(payload);
        vm.prank(carrier);
        vault.attestCarrierEvidence(id, h, hex"deadbeef", payload);

        SweeftVault.Escrow memory e = vault.getEscrow(id);
        assertTrue(e.carrierAttested);
        assertEq(e.carrierPayloadHash, h);
        assertEq(e.carrierSigner, carrier);
        assertTrue(e.evidenceAttested);
        assertTrue(e.delivered);
    }

    function test_attestCarrierEvidence_notCarrier() public {
        vm.prank(buyer);
        uint256 id = vault.createEscrowWithLogistics(buyer, seller, carrier, uint64(block.timestamp + 7 days), 1 ether, 0.1 ether);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vault.fundEscrow{value: 1 ether}(id);

        bytes memory payload = "sweaft-carrier-v1|LOG-DEMO-001|DEMO-123|1|DELIVERED|CREATED@0";
        vm.expectRevert(SweeftVault.NotCarrier.selector);
        vault.attestCarrierEvidence(id, keccak256(payload), hex"00", payload);
    }

    function test_attestCarrierEvidence_badSignature() public {
        vm.prank(buyer);
        uint256 id = vault.createEscrowWithLogistics(buyer, seller, carrier, uint64(block.timestamp + 7 days), 1 ether, 0);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vault.fundEscrow{value: 1 ether}(id);

        MockVerify(0x0000000000000000000000000000000000000a01).setResult(false);
        bytes memory payload = "sweaft-carrier-v1|LOG-DEMO-001|DEMO-123|1|DELIVERED|CREATED@0";
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadCarrierSignature.selector);
        vault.attestCarrierEvidence(id, keccak256(payload), hex"00", payload);
    }

    function test_attestCarrierEvidence_badHash() public {
        vm.prank(buyer);
        uint256 id = vault.createEscrowWithLogistics(buyer, seller, carrier, uint64(block.timestamp + 7 days), 1 ether, 0);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vault.fundEscrow{value: 1 ether}(id);

        bytes memory payload = "sweaft-carrier-v1|LOG-DEMO-001|DEMO-123|1|DELIVERED|CREATED@0";
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadPayloadHash.selector);
        vault.attestCarrierEvidence(id, keccak256("tampered"), hex"00", payload);
    }

    function test_release_withLogistics_paysCarrier() public {
        uint256 total = 1.1 ether;
        uint256 log = 0.1 ether;
        vm.prank(buyer);
        uint256 id = vault.createEscrowWithLogistics(buyer, seller, carrier, uint64(block.timestamp + 7 days), total, log);
        vm.deal(buyer, total);
        vm.prank(buyer);
        vault.fundEscrow{value: total}(id);
        vm.prank(buyer);
        vault.confirmReceipt(id);

        uint256 sellerBefore = seller.balance;
        uint256 carrierBefore = carrier.balance;
        uint256 treasuryBefore = treasury.balance;

        vault.release(id, hex"deadbeef");

        uint256 goods = total - log;
        uint256 fee = (goods * FEE_BPS) / 10000;
        uint256 sellerAmt = goods - fee;
        uint256 treasuryShare = (fee * 7000) / 10000;
        uint256 disputeShare = fee - treasuryShare;

        assertEq(seller.balance, sellerBefore + sellerAmt);
        assertEq(carrier.balance, carrierBefore + log);
        assertEq(treasury.balance, treasuryBefore + treasuryShare);
        assertEq(board.rewardPool(), disputeShare);
        assertEq(uint8(vault.getEscrow(id).status), uint8(SweeftVault.EscrowStatus.Completed));
    }

    function test_marketplace_listingWithLogistics() public {
        vm.prank(seller);
        uint256 lid = market.createListingWithLogistics(1.1 ether, 1, "uri", keccak256("m"), carrier, 0.1 ether);
        SweeftMarketplace.Listing memory l = market.getListing(lid);
        assertEq(l.logisticsPartner, carrier);
        assertEq(l.logisticsFee, 0.1 ether);

        vm.deal(buyer, 1.1 ether);
        vm.prank(buyer);
        uint256 escrowId = market.purchase{value: 1.1 ether}(lid, uint64(block.timestamp + 7 days));
        SweeftVault.Escrow memory e = vault.getEscrow(escrowId);
        assertEq(e.logisticsPartner, carrier);
        assertEq(e.logisticsAmount, 0.1 ether);
        assertEq(e.amount, 1.1 ether);
        assertEq(uint8(e.status), uint8(SweeftVault.EscrowStatus.Funded));
    }

    function test_dispute_refund_includesLogistics() public {
        uint256 total = 1.1 ether;
        vm.prank(buyer);
        uint256 id = vault.createEscrowWithLogistics(buyer, seller, carrier, uint64(block.timestamp + 7 days), total, 0.1 ether);
        vm.deal(buyer, total);
        vm.prank(buyer);
        vault.fundEscrow{value: total}(id);
        vm.prank(buyer);
        vault.raiseDispute(id);
        // board would settle; here refund path via pq needed — simulate board call
        vm.prank(address(board));
        uint256 buyerBefore = buyer.balance;
        vault.resolveDispute(id, false);
        assertEq(buyer.balance, buyerBefore + total);
        assertEq(uint8(vault.getEscrow(id).status), uint8(SweeftVault.EscrowStatus.Refunded));
    }
}
