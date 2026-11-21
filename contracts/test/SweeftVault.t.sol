// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SweeftVault, IPQCVerify, IPQCKeyStatus } from "../src/SweeftVault.sol";

// ----------------------------------------------------------------------
// Mocks for QoreChain precompiles (the local EVM has none)
// ----------------------------------------------------------------------

contract MockOracleRegistry {
    mapping(address => bool) public verifiers;

    function setVerifier(address account, bool enabled) external {
        verifiers[account] = enabled;
    }

    function isVerifier(address account) external view returns (bool) {
        return verifiers[account];
    }
}

contract MockPQCKeyStatus {
    struct Key {
        bool registered;
        bool proven;
        bytes pubkey;
    }

    mapping(address => Key) internal keys;

    function setKey(address account, bytes memory pubkey, bool registered, bool proven) external {
        keys[account] = Key({ registered: registered, proven: proven, pubkey: pubkey });
    }

    function pqcKeyStatus(address account)
        external
        view
        returns (bool registered, uint8 algorithmId, bytes memory pubkey, bool proven)
    {
        Key storage k = keys[account];
        return (k.registered, 1, k.pubkey, k.proven);
    }
}

contract MockPQCVerify {
    bool public result = true;

    function setResult(bool value) external {
        result = value;
    }

    function pqcVerify(bytes calldata, bytes calldata, bytes calldata) external view returns (bool) {
        return result;
    }
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

contract SweeftVaultTest is Test {
    SweeftVault internal vault;
    MockOracleRegistry internal oracle;
    MockPQCKeyStatus internal keyStatus;
    MockPQCVerify internal verifier;

    address internal buyer = address(0xB0B);
    address internal seller = address(0x5E11E);
    address internal stranger = address(0xCAFE);
    address internal oracleVerifier = address(0x0AC1E);
    address internal treasury = address(0x7EA5);

    uint256 internal constant FEE_BPS = 200; // 2%

    bytes internal buyerPqcKey = hex"deadbeef";
    bytes internal dummySig = hex"c0ffee";

    address internal constant PQC_VERIFY_ADDR = 0x0000000000000000000000000000000000000a01;
    address internal constant PQC_KEY_STATUS_ADDR = 0x0000000000000000000000000000000000000a02;

    function setUp() public {
        oracle = new MockOracleRegistry();
        vault = new SweeftVault(address(oracle), "qorechain-diana", FEE_BPS, treasury);

        // Etch precompile mocks at the fixed QoreChain addresses. The etched
        // copies have fresh storage, so initialize them through their ABI.
        keyStatus = new MockPQCKeyStatus();
        verifier = new MockPQCVerify();
        vm.etch(PQC_KEY_STATUS_ADDR, address(keyStatus).code);
        vm.etch(PQC_VERIFY_ADDR, address(verifier).code);

        MockPQCKeyStatus(PQC_KEY_STATUS_ADDR).setKey(buyer, buyerPqcKey, true, true);
        MockPQCVerify(PQC_VERIFY_ADDR).setResult(true);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _deadline(uint64 offset) internal view returns (uint64) {
        return uint64(block.timestamp + offset);
    }

    function _createAndFund(uint256 amount, uint64 deadlineOffset) internal returns (uint256) {
        vm.prank(buyer);
        uint256 id = vault.createEscrow(buyer, seller, _deadline(deadlineOffset), amount);
        vm.deal(buyer, amount);
        vm.prank(buyer);
        vault.fundEscrow{ value: amount }(id);
        return id;
    }

    // ------------------------------------------------------------------
    // 1. Create + fund
    // ------------------------------------------------------------------

    function test_CreateEscrow() public {
        vm.prank(buyer);
        uint256 id = vault.createEscrow(buyer, seller, _deadline(2 days), 1 ether);
        assertEq(id, 0);

        SweeftVault.Escrow memory e = vault.getEscrow(id);
        assertEq(e.buyer, buyer);
        assertEq(e.seller, seller);
        assertEq(e.amount, 1 ether);
        assertEq(uint8(e.status), uint8(SweeftVault.EscrowStatus.None));
    }

    function test_CreateEscrow_RevertsOnZeroSeller() public {
        vm.expectRevert(SweeftVault.InvalidParties.selector);
        vault.createEscrow(buyer, address(0), _deadline(1 days), 1 ether);
    }

    function test_CreateEscrow_RevertsOnZeroAmount() public {
        vm.expectRevert(SweeftVault.InvalidAmount.selector);
        vault.createEscrow(buyer, seller, _deadline(1 days), 0);
    }

    function test_FundEscrow_OnlyBuyer() public {
        vm.prank(buyer);
        uint256 id = vault.createEscrow(buyer, seller, _deadline(1 days), 1 ether);
        vm.deal(stranger, 1 ether);

        vm.prank(stranger);
        vm.expectRevert(SweeftVault.NotBuyer.selector);
        vault.fundEscrow{ value: 1 ether }(id);
    }

    function test_FundEscrow_ExactAmountRequired() public {
        vm.prank(buyer);
        uint256 id = vault.createEscrow(buyer, seller, _deadline(1 days), 1 ether);
        vm.deal(buyer, 2 ether);

        vm.prank(buyer);
        vm.expectRevert(SweeftVault.WrongDeposit.selector);
        vault.fundEscrow{ value: 0.5 ether }(id);
    }

    function test_FundEscrow_NoDoubleDeposit() public {
        uint256 id = _createAndFund(1 ether, 1 days);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(SweeftVault.InvalidStatus.selector);
        vault.fundEscrow{ value: 1 ether }(id);
    }

    // ------------------------------------------------------------------
    // 2. Cancel
    // ------------------------------------------------------------------

    function test_CancelEscrow_ByBuyer() public {
        vm.prank(buyer);
        uint256 id = vault.createEscrow(buyer, seller, _deadline(1 days), 1 ether);
        vm.prank(buyer);
        vault.cancelEscrow(id);
        assertEq(uint8(vault.getEscrow(id).status), uint8(SweeftVault.EscrowStatus.Cancelled));
    }

    function test_CancelEscrow_BySeller() public {
        vm.prank(buyer);
        uint256 id = vault.createEscrow(buyer, seller, _deadline(1 days), 1 ether);
        vm.prank(seller);
        vault.cancelEscrow(id);
        assertEq(uint8(vault.getEscrow(id).status), uint8(SweeftVault.EscrowStatus.Cancelled));
    }

    function test_CancelEscrow_StrangerRejected() public {
        vm.prank(buyer);
        uint256 id = vault.createEscrow(buyer, seller, _deadline(1 days), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(SweeftVault.InvalidParties.selector);
        vault.cancelEscrow(id);
    }

    function test_CancelEscrow_FundedRejected() public {
        uint256 id = _createAndFund(1 ether, 1 days);
        vm.prank(buyer);
        vm.expectRevert(SweeftVault.InvalidStatus.selector);
        vault.cancelEscrow(id);
    }

    // ------------------------------------------------------------------
    // 3. Release — buyer confirmation path
    // ------------------------------------------------------------------

    function test_Release_AfterConfirmReceipt() public {
        uint256 id = _createAndFund(1 ether, 7 days);

        vm.prank(buyer);
        vault.confirmReceipt(id);

        assertTrue(vault.isReleaseEligible(id));

        uint256 sellerBefore = seller.balance;
        uint256 treasuryBefore = treasury.balance;
        vault.release(id, dummySig);

        // 2% fee: seller gets 0.98, treasury the full fee (no dispute board set).
        uint256 fee = (1 ether * FEE_BPS) / 10_000;
        assertEq(seller.balance, sellerBefore + 1 ether - fee);
        assertEq(treasury.balance, treasuryBefore + fee);
        SweeftVault.Escrow memory e = vault.getEscrow(id);
        assertEq(uint8(e.status), uint8(SweeftVault.EscrowStatus.Completed));
        assertTrue(e.released);
    }

    function test_Release_RevertsWithoutConfirmationOrDelivery() public {
        uint256 id = _createAndFund(1 ether, 7 days);

        vm.expectRevert(SweeftVault.NotReleaseEligible.selector);
        vault.release(id, dummySig);
    }

    function test_ConfirmReceipt_OnlyBuyer() public {
        uint256 id = _createAndFund(1 ether, 7 days);

        vm.prank(stranger);
        vm.expectRevert(SweeftVault.NotBuyer.selector);
        vault.confirmReceipt(id);
    }

    // ------------------------------------------------------------------
    // 4. Release — delivered + inspection window (deadline) path
    // ------------------------------------------------------------------

    function test_Release_AfterDeliveredAndDeadline() public {
        uint256 id = _createAndFund(1 ether, 7 days);

        vm.prank(seller);
        vault.markDelivered(id);

        // Deadline not reached yet.
        assertFalse(vault.isReleaseEligible(id));
        vm.expectRevert(SweeftVault.NotReleaseEligible.selector);
        vault.release(id, dummySig);

        // Inspection window passes.
        vm.warp(block.timestamp + 7 days);
        assertTrue(vault.isReleaseEligible(id));
        vault.release(id, dummySig);
    }

    function test_Release_AfterAttestedAndDeadline() public {
        uint256 id = _createAndFund(1 ether, 7 days);
        oracle.setVerifier(oracleVerifier, true);

        vm.prank(oracleVerifier);
        vault.attestEvidence(id, keccak256("proof"));

        vm.warp(block.timestamp + 7 days);
        assertTrue(vault.isReleaseEligible(id));
        vault.release(id, dummySig);
    }

    // ------------------------------------------------------------------
    // 5. PQC enforcement
    // ------------------------------------------------------------------

    function test_Release_RejectsUnregisteredGuardianKey() public {
        uint256 id = _createAndFund(1 ether, 7 days);
        vm.prank(buyer);
        vault.confirmReceipt(id);

        MockPQCKeyStatus(PQC_KEY_STATUS_ADDR).setKey(buyer, "", false, false);

        vm.expectRevert(SweeftVault.GuardianKeyNotRegistered.selector);
        vault.release(id, dummySig);
    }

    function test_Release_RejectsUnprovenKey() public {
        uint256 id = _createAndFund(1 ether, 7 days);
        vm.prank(buyer);
        vault.confirmReceipt(id);

        MockPQCKeyStatus(PQC_KEY_STATUS_ADDR).setKey(buyer, buyerPqcKey, true, false);

        vm.expectRevert(SweeftVault.GuardianKeyNotProven.selector);
        vault.release(id, dummySig);
    }

    function test_Release_RejectsBadSignature() public {
        uint256 id = _createAndFund(1 ether, 7 days);
        vm.prank(buyer);
        vault.confirmReceipt(id);

        MockPQCVerify(PQC_VERIFY_ADDR).setResult(false);

        vm.expectRevert(SweeftVault.BadPqcSignature.selector);
        vault.release(id, dummySig);
    }

    function test_Release_ReplayRejected() public {
        uint256 id = _createAndFund(1 ether, 7 days);
        vm.prank(buyer);
        vault.confirmReceipt(id);

        vault.release(id, dummySig);

        // Same escrow cannot be released twice; nonce has advanced.
        vm.expectRevert(SweeftVault.NotReleaseEligible.selector);
        vault.release(id, dummySig);

        // Nonce incremented exactly once.
        assertEq(vault.pqcNonce(buyer), 1);
    }

    function test_Release_AnyoneCanSubmit() public {
        uint256 id = _createAndFund(1 ether, 7 days);
        vm.prank(buyer);
        vault.confirmReceipt(id);

        uint256 sellerBefore = seller.balance;
        vm.prank(stranger);
        vault.release(id, dummySig);

        uint256 fee = (1 ether * FEE_BPS) / 10_000;
        assertEq(seller.balance, sellerBefore + 1 ether - fee);
    }

    // ------------------------------------------------------------------
    // 6. Refund
    // ------------------------------------------------------------------

    function test_Refund_AfterDeadline() public {
        uint256 id = _createAndFund(1 ether, 7 days);
        uint256 buyerBefore = buyer.balance;

        assertFalse(vault.isRefundable(id));
        vm.expectRevert(SweeftVault.NotRefundable.selector);
        vault.refundAfterDeadline(id, dummySig);

        vm.warp(block.timestamp + 7 days);
        assertTrue(vault.isRefundable(id));

        vault.refundAfterDeadline(id, dummySig);

        assertEq(buyer.balance, buyerBefore + 1 ether);
        assertEq(uint8(vault.getEscrow(id).status), uint8(SweeftVault.EscrowStatus.Refunded));
    }

    function test_Refund_BlockedOnceAttested() public {
        uint256 id = _createAndFund(1 ether, 7 days);
        oracle.setVerifier(oracleVerifier, true);

        vm.prank(oracleVerifier);
        vault.attestEvidence(id, keccak256("proof"));

        vm.warp(block.timestamp + 7 days);

        assertFalse(vault.isRefundable(id));
        vm.expectRevert(SweeftVault.NotRefundable.selector);
        vault.refundAfterDeadline(id, dummySig);
    }

    function test_Refund_RejectsBadSignature() public {
        uint256 id = _createAndFund(1 ether, 7 days);
        vm.warp(block.timestamp + 7 days);

        MockPQCVerify(PQC_VERIFY_ADDR).setResult(false);

        vm.expectRevert(SweeftVault.BadPqcSignature.selector);
        vault.refundAfterDeadline(id, dummySig);
    }

    // ------------------------------------------------------------------
    // 7. Oracle authorization
    // ------------------------------------------------------------------

    function test_Attest_OnlyAuthorizedVerifier() public {
        uint256 id = _createAndFund(1 ether, 7 days);

        vm.prank(stranger);
        vm.expectRevert(SweeftVault.NotVerifier.selector);
        vault.attestEvidence(id, keccak256("proof"));

        oracle.setVerifier(oracleVerifier, true);
        vm.prank(oracleVerifier);
        vault.attestEvidence(id, keccak256("proof"));

        assertTrue(vault.getEscrow(id).evidenceAttested);
    }

    // ------------------------------------------------------------------
    // 8. Invalid state transitions
    // ------------------------------------------------------------------

    function test_MarkDelivered_OnlySeller() public {
        uint256 id = _createAndFund(1 ether, 7 days);

        vm.prank(stranger);
        vm.expectRevert(SweeftVault.NotSeller.selector);
        vault.markDelivered(id);
    }

    function test_Release_RejectedOnCompletedEscrow() public {
        uint256 id = _createAndFund(1 ether, 7 days);
        vm.prank(buyer);
        vault.confirmReceipt(id);
        vault.release(id, dummySig);

        // Escrow is terminal; release again must fail on eligibility, not payment.
        vm.expectRevert(SweeftVault.NotReleaseEligible.selector);
        vault.release(id, dummySig);
    }

    function test_FundEscrow_RevertsOnUnknownEscrow() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(SweeftVault.InvalidEscrow.selector);
        vault.fundEscrow{ value: 1 ether }(999);
    }

    function test_Attest_RejectedOnUnknownEscrow() public {
        oracle.setVerifier(oracleVerifier, true);
        vm.prank(oracleVerifier);
        vm.expectRevert(SweeftVault.InvalidStatus.selector);
        vault.attestEvidence(999, keccak256("proof"));
    }
}
