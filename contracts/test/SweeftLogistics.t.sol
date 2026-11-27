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
    function setResult(bool r) external { result = r; }
    function pqcVerify(bytes calldata, bytes calldata, bytes calldata) external view returns (bool) { return result; }
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
        board = new SweeftDisputeBoard(address(vault), treasury);
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

    function _fundedLogisticsEscrow(uint256 total, uint256 log) internal returns (uint256 id) {
        vm.deal(buyer, total);
        vm.prank(buyer);
        id = vault.createEscrowWithLogistics(buyer, seller, carrier, uint64(block.timestamp + 7 days), total, log);
        vm.prank(buyer);
        vault.fundEscrow{value: total}(id);
    }

    function _attestDelivered(uint256 id) internal {
        vm.prank(carrier);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", bytes32(uint256(0x1234)), uint64(block.timestamp), uint64(block.timestamp + 7 days), hex"deadbeef");
    }

    function test_registerCarrier_ownerOnly() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(SweeftVault.NotOwner.selector);
        vault.registerCarrier(address(0xBEEF), "LOG-X");
    }

    function test_attestCarrierEvidence_valid() public {
        uint256 id = _fundedLogisticsEscrow(1 ether, 0.1 ether);

        vm.prank(carrier);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", bytes32(uint256(0x1234)), uint64(block.timestamp), uint64(block.timestamp + 7 days), hex"deadbeef");

        SweeftVault.Escrow memory e = vault.getEscrow(id);
        assertTrue(e.carrierAttested);
        assertEq(e.carrierSigner, carrier);
        assertTrue(e.evidenceAttested);
        assertTrue(e.carrierDelivered);
        assertEq(e.carrierStatus, "DELIVERED");
    }

    function test_attestCarrierEvidence_notCarrier() public {
        uint256 id = _fundedLogisticsEscrow(1 ether, 0.1 ether);

        vm.expectRevert(SweeftVault.NotCarrier.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", bytes32(uint256(0x1234)), uint64(block.timestamp), uint64(block.timestamp + 7 days), hex"00");
    }

    function test_attestCarrierEvidence_otherCarrierRejected() public {
        // A registered carrier that is not this escrow's logistics partner
        // cannot attest for it (binds the attestation to the escrow).
        address other = address(0xDEAD);
        vault.registerCarrier(other, "LOG-OTHER-002");
        MockKeyStatus(0x0000000000000000000000000000000000000a02).setRegistered(other, true, true);

        uint256 id = _fundedLogisticsEscrow(1 ether, 0.1 ether);
        vm.prank(other);
        vm.expectRevert(SweeftVault.NotCarrier.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", bytes32(uint256(0x1234)), uint64(block.timestamp), uint64(block.timestamp + 7 days), hex"00");
    }

    function test_attestCarrierEvidence_badSignature() public {
        uint256 id = _fundedLogisticsEscrow(1 ether, 0);

        MockVerify(0x0000000000000000000000000000000000000a01).setResult(false);
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadCarrierSignature.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", bytes32(uint256(0x1234)), uint64(block.timestamp), uint64(block.timestamp + 7 days), hex"00");
    }

    function test_attestCarrierEvidence_staleRejected() public {
        uint256 id = _fundedLogisticsEscrow(1 ether, 0);
        vm.warp(block.timestamp + 30 days);
        uint64 stale = uint64(block.timestamp - 8 days);
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.StaleAttestation.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", bytes32(uint256(0x1234)), stale, uint64(block.timestamp + 7 days), hex"00");
    }

    function test_nonDeliveredStatusDoesNotFulfil() public {
        uint256 id = _fundedLogisticsEscrow(1 ether, 0.1 ether);

        vm.prank(carrier);
        vault.attestCarrierEvidence(id, "DEMO-123", "LOST", bytes32(uint256(0x1234)), uint64(block.timestamp), uint64(block.timestamp + 7 days), hex"deadbeef");

        SweeftVault.Escrow memory e = vault.getEscrow(id);
        assertTrue(e.carrierAttested);
        assertFalse(e.delivered);
        assertFalse(e.evidenceAttested);
        assertEq(e.carrierStatus, "LOST");
    }

    function test_release_withLogistics_paysCarrierWhenDelivered() public {
        uint256 total = 1.1 ether;
        uint256 log = 0.1 ether;
        uint256 id = _fundedLogisticsEscrow(total, log);
        _attestDelivered(id);
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

        // Credits-only settlement: shares accrue, then each party withdraws.
        assertEq(vault.credits(seller), sellerAmt);
        assertEq(vault.credits(carrier), log);
        assertEq(vault.credits(treasury), treasuryShare);
        assertEq(vault.credits(address(board)), disputeShare);
        vm.prank(seller);
        vault.withdrawCredits();
        vm.prank(carrier);
        vault.withdrawCredits();
        vm.prank(treasury);
        vault.withdrawCredits();
        board.withdrawVaultCredits(); // board pulls its credit into rewardPool
        assertEq(seller.balance, sellerBefore + sellerAmt);
        assertEq(carrier.balance, carrierBefore + log);
        assertEq(treasury.balance, treasuryBefore + treasuryShare);
        assertEq(board.rewardPool(), disputeShare);
        assertEq(uint8(vault.getEscrow(id).status), uint8(SweeftVault.EscrowStatus.Completed));
    }

    function test_release_withoutCarrierAttestation_holdsLogisticsForBuyer() public {
        uint256 total = 1.1 ether;
        uint256 log = 0.1 ether;
        uint256 id = _fundedLogisticsEscrow(total, log);
        vm.prank(buyer);
        vault.confirmReceipt(id);

        uint256 carrierBefore = carrier.balance;
        vault.release(id, hex"deadbeef");

        // Carrier never proved delivery: it is not paid, and the logistics
        // share is credited to the buyer.
        assertEq(carrier.balance, carrierBefore);
        assertEq(vault.credits(buyer), log);
    }

    function test_marketplace_listingWithLogistics() public {
        vm.prank(seller);
        uint256 lid = market.createListingWithLogistics(1.1 ether, 1, "uri", keccak256("m"), carrier, 0.1 ether);
        SweeftMarketplace.Listing memory l = market.getListing(lid);
        assertEq(l.logisticsPartner, carrier);
        assertEq(l.logisticsFee, 0.1 ether);

        vm.deal(buyer, 1.1 ether);
        vm.prank(buyer);
        uint256 escrowId = market.purchase{value: 1.1 ether}(lid, uint64(block.timestamp + 7 days), 1.1 ether, keccak256("m"));
        SweeftVault.Escrow memory e = vault.getEscrow(escrowId);
        assertEq(e.logisticsPartner, carrier);
        assertEq(e.logisticsAmount, 0.1 ether);
        assertEq(e.amount, 1.1 ether);
        assertEq(uint8(e.status), uint8(SweeftVault.EscrowStatus.Funded));
    }

    function test_refund_includesLogistics() public {
        uint256 total = 1.1 ether;
        uint256 id = _fundedLogisticsEscrow(total, 0.1 ether);
        // No carrier DELIVERED proof, so after the deadline the buyer refunds
        // the full amount (goods + logistics).
        vm.warp(block.timestamp + 7 days + 1);
        uint256 buyerBefore = buyer.balance;
        vault.refundAfterDeadline(id, hex"c0ffee");
        assertEq(vault.credits(buyer), total);
        vm.prank(buyer);
        vault.withdrawCredits();
        assertEq(buyer.balance, buyerBefore + total);
        assertEq(uint8(vault.getEscrow(id).status), uint8(SweeftVault.EscrowStatus.Refunded));
    }

    // ------------------------------------------------------------------
    // Residual-review regressions (N-6, N-7, N-8)
    // ------------------------------------------------------------------

    function test_carrierStatusAndTrackingAreBounded() public {
        uint256 id = _fundedLogisticsEscrow(1 ether, 0.1 ether);

        // 33-byte status exceeds MAX_STATUS_LEN (32).
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadStatus.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", bytes32(uint256(0x1234)), uint64(block.timestamp), uint64(block.timestamp + 7 days), hex"");

        // 129-byte tracking exceeds MAX_TRACKING_LEN (128).
        bytes memory longTracking = new bytes(129);
        for (uint256 i = 0; i < 129; i++) longTracking[i] = "A";
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadStatus.selector);
        vault.attestCarrierEvidence(id, string(longTracking), "DELIVERED", bytes32(uint256(0x1234)), uint64(block.timestamp), uint64(block.timestamp + 7 days), hex"");
    }

    function test_carrierNonceIsPerEscrow() public {
        uint256 a = _fundedLogisticsEscrow(1 ether, 0.1 ether);
        uint256 b = _fundedLogisticsEscrow(1 ether, 0);
        _attestDelivered(a);
        _attestDelivered(b);

        // Each shipment has its own nonce, so concurrent deliveries do not
        // invalidate each other (N-6).
        assertEq(vault.carrierNonce(carrier, a), 1);
        assertEq(vault.carrierNonce(carrier, b), 1);
    }

    function test_laterLostAttestationSupersedesDelivered() public {
        uint256 id = _fundedLogisticsEscrow(1 ether, 0.1 ether);
        _attestDelivered(id);
        assertTrue(vault.getEscrow(id).carrierDelivered);

        // The same shipment is later reported LOST: the latest-status rule
        // clears the delivery proof (N-8) and reopens the refund path.
        vm.prank(carrier);
        vault.attestCarrierEvidence(id, "DEMO-123", "LOST", bytes32(uint256(0x1234)), uint64(block.timestamp), uint64(block.timestamp + 7 days), hex"deadbeef");

        SweeftVault.Escrow memory e = vault.getEscrow(id);
        assertTrue(e.carrierAttested);
        assertFalse(e.carrierDelivered);
        assertFalse(e.evidenceAttested);
        assertEq(e.carrierStatus, "LOST");

        vm.warp(block.timestamp + 7 days + 1);
        assertTrue(vault.isRefundable(id));
    }

    function test_inTransitAttestationDoesNotPayCarrier() public {
        uint256 total = 1.1 ether;
        uint256 log = 0.1 ether;
        uint256 id = _fundedLogisticsEscrow(total, log);
        _attestDelivered(id);
        vm.prank(carrier);
        vault.attestCarrierEvidence(id, "DEMO-123", "IN_TRANSIT", bytes32(uint256(0x1234)), uint64(block.timestamp), uint64(block.timestamp + 7 days), hex"deadbeef");
        assertFalse(vault.getEscrow(id).carrierDelivered);

        vm.prank(buyer);
        vault.confirmReceipt(id);
        uint256 carrierBefore = carrier.balance;
        vault.release(id, hex"deadbeef");

        // No DELIVERED proof, so the logistics share is held for the buyer.
        assertEq(carrier.balance, carrierBefore);
        assertEq(vault.credits(buyer), log);
    }
}
