// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SweeftVault } from "../src/SweeftVault.sol";
import { SweeftOracleRegistry } from "../src/SweeftOracleRegistry.sol";
import { SweeftDisputeBoard } from "../src/SweeftDisputeBoard.sol";

contract SweeftDisputeBoardTest is Test {
    SweeftVault internal vault;
    SweeftOracleRegistry internal registry;
    SweeftDisputeBoard internal board;

    address internal buyer = address(0xB0B);
    address internal seller = address(0x5E11E);
    address internal resolver1 = address(0xA1);
    address internal resolver2 = address(0xA2);
    address internal resolver3 = address(0xA3);
    address internal resolver4 = address(0xA4);
    address internal verifier = address(0x0AC1E);
    address internal treasury = address(0x7EA5);

    uint256 internal constant AMOUNT = 1 ether;
    uint256 internal constant FEE_BPS = 200;

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        vault = new SweeftVault(address(registry), "qorechain-diana", FEE_BPS, treasury);
        board = new SweeftDisputeBoard(address(vault));
        vault.setDisputeBoard(address(board));
        board.setVotingPeriod(1 hours);
        board.setUnstakeCooldown(1 hours);

        // Four funded, staked resolvers (20 QOR each).
        address[4] memory resolvers = [resolver1, resolver2, resolver3, resolver4];
        for (uint256 i = 0; i < resolvers.length; i++) {
            vm.deal(resolvers[i], 30 ether);
            vm.prank(resolvers[i]);
            board.stake{ value: 20 ether }();
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _fundedEscrow() internal returns (uint256) {
        vm.prank(buyer);
        uint256 id = vault.createEscrow(buyer, seller, uint64(block.timestamp + 7 days), AMOUNT);
        vm.deal(buyer, AMOUNT);
        vm.prank(buyer);
        vault.fundEscrow{ value: AMOUNT }(id);
        return id;
    }

    function _openDispute() internal returns (uint256 escrowId, uint256 disputeId) {
        escrowId = _fundedEscrow();
        vm.prank(buyer);
        disputeId = board.openDispute(escrowId);
    }

    function _openAndJoin() internal returns (uint256 escrowId, uint256 disputeId) {
        (escrowId, disputeId) = _openDispute();
        vm.prank(resolver1);
        board.joinDispute(disputeId);
        vm.prank(resolver2);
        board.joinDispute(disputeId);
        vm.prank(resolver3);
        board.joinDispute(disputeId);
    }

    // ------------------------------------------------------------------
    // Staking
    // ------------------------------------------------------------------

    function test_Stake_And_Withdraw_AfterCooldown() public {
        vm.deal(address(0xAA), 25 ether);
        vm.prank(address(0xAA));
        board.stake{ value: 20 ether }();
        assertEq(board.stakeOf(address(0xAA)), 20 ether);

        vm.prank(address(0xAA));
        board.requestUnstake();

        vm.prank(address(0xAA));
        vm.expectRevert(SweeftDisputeBoard.CooldownActive.selector);
        board.withdrawStake();

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 before = address(0xAA).balance;
        vm.prank(address(0xAA));
        board.withdrawStake();
        assertEq(address(0xAA).balance, before + 20 ether);
        assertEq(board.stakeOf(address(0xAA)), 0);
    }

    function test_RequestUnstake_BlockedWhileOnBoard() public {
        (, uint256 disputeId) = _openDispute();
        vm.prank(resolver1);
        board.joinDispute(disputeId);

        vm.prank(resolver1);
        vm.expectRevert(SweeftDisputeBoard.StakeLocked.selector);
        board.requestUnstake();
    }

    // ------------------------------------------------------------------
    // Dispute lifecycle
    // ------------------------------------------------------------------

    function test_OpenDispute_ByBuyer_FreezesEscrow() public {
        uint256 escrowId = _fundedEscrow();

        vm.prank(buyer);
        uint256 disputeId = board.openDispute(escrowId);

        SweeftVault.Escrow memory e = vault.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(SweeftVault.EscrowStatus.Disputed));
        assertFalse(vault.isReleaseEligible(escrowId));
        assertFalse(vault.isRefundable(escrowId));

        uint256 storedEscrow;
        (storedEscrow,,,,,,,,,) = board.getDispute(disputeId);
        assertEq(storedEscrow, escrowId);
    }

    function test_OpenDispute_BySeller() public {
        uint256 escrowId = _fundedEscrow();
        vm.prank(seller);
        board.openDispute(escrowId);
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Disputed));
    }

    function test_OpenDispute_StrangerRejected() public {
        uint256 escrowId = _fundedEscrow();
        vm.prank(address(0xCAFE));
        vm.expectRevert(SweeftDisputeBoard.ExcludedParty.selector);
        board.openDispute(escrowId);
    }

    function test_OpenDispute_OutsideVaultPath() public {
        // Buyer may also freeze via the vault directly; the board rejects a
        // second freeze (already Disputed).
        uint256 escrowId = _fundedEscrow();
        vm.prank(buyer);
        vault.raiseDispute(escrowId);

        vm.prank(seller);
        vm.expectRevert(SweeftVault.NotDisputable.selector);
        board.openDispute(escrowId);
    }

    // ------------------------------------------------------------------
    // Board formation
    // ------------------------------------------------------------------

    function test_Join_RequiresMinStake() public {
        vm.deal(address(0xBEEF), 19 ether);
        vm.prank(address(0xBEEF));
        board.stake{ value: 19 ether }();

        (, uint256 disputeId) = _openDispute();
        vm.prank(address(0xBEEF));
        vm.expectRevert(SweeftDisputeBoard.StakeTooLow.selector);
        board.joinDispute(disputeId);
    }

    function test_Join_ExcludesParties() public {
        (, uint256 disputeId) = _openDispute();

        // Parties are excluded even when staked.
        vm.deal(buyer, 25 ether);
        vm.prank(buyer);
        board.stake{ value: 20 ether }();
        vm.deal(seller, 25 ether);
        vm.prank(seller);
        board.stake{ value: 20 ether }();

        vm.prank(buyer);
        vm.expectRevert(SweeftDisputeBoard.ExcludedParty.selector);
        board.joinDispute(disputeId);

        vm.prank(seller);
        vm.expectRevert(SweeftDisputeBoard.ExcludedParty.selector);
        board.joinDispute(disputeId);
    }

    function test_Join_ExcludesVerifier() public {
        uint256 escrowId = _fundedEscrow();
        registry.addVerifier(verifier);
        vm.prank(verifier);
        vault.attestEvidence(escrowId, keccak256("proof"));

        vm.prank(buyer);
        uint256 disputeId = board.openDispute(escrowId);

        // Verifier has no stake — fund and stake them, still excluded.
        vm.deal(verifier, 25 ether);
        vm.prank(verifier);
        board.stake{ value: 20 ether }();

        vm.prank(verifier);
        vm.expectRevert(SweeftDisputeBoard.ExcludedParty.selector);
        board.joinDispute(disputeId);
    }

    function test_Join_MaxThree() public {
        (, uint256 disputeId) = _openDispute();

        vm.prank(resolver1);
        board.joinDispute(disputeId);
        vm.prank(resolver2);
        board.joinDispute(disputeId);
        vm.prank(resolver3);
        board.joinDispute(disputeId);
        vm.prank(resolver4);
        vm.expectRevert(SweeftDisputeBoard.BoardFull.selector);
        board.joinDispute(disputeId);
    }

    function test_Join_DoubleJoinRejected() public {
        (, uint256 disputeId) = _openDispute();
        vm.prank(resolver1);
        board.joinDispute(disputeId);
        vm.prank(resolver1);
        vm.expectRevert(SweeftDisputeBoard.AlreadyMember.selector);
        board.joinDispute(disputeId);
    }

    // ------------------------------------------------------------------
    // Voting and settlement
    // ------------------------------------------------------------------

    function test_Vote_MajorityRelease_PaysSellerMinusFee() public {
        (uint256 escrowId, uint256 disputeId) = _openAndJoin();

        uint256 sellerBefore = seller.balance;
        uint256 treasuryBefore = treasury.balance;
        uint256 boardBefore = board.rewardPool();

        vm.prank(resolver1);
        board.castVote(disputeId, true);
        vm.prank(resolver2);
        board.castVote(disputeId, true);

        uint256 fee = (AMOUNT * FEE_BPS) / 10_000; // 0.02 ether
        assertEq(seller.balance, sellerBefore + AMOUNT - fee);
        assertEq(treasury.balance, treasuryBefore + (fee * 7000) / 10_000); // 70%
        assertEq(board.rewardPool(), boardBefore + (fee * 3000) / 10_000); // 30%

        SweeftVault.Escrow memory e = vault.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(SweeftVault.EscrowStatus.Completed));
    }

    function test_Vote_MajorityRefund_FullRefundNoFee() public {
        (uint256 escrowId, uint256 disputeId) = _openAndJoin();

        uint256 buyerBefore = buyer.balance;
        vm.prank(resolver1);
        board.castVote(disputeId, false);
        vm.prank(resolver2);
        board.castVote(disputeId, false);

        assertEq(buyer.balance, buyerBefore + AMOUNT); // full refund, no fee
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Refunded));
    }

    function test_Vote_SplitThenFinish() public {
        (, uint256 disputeId) = _openAndJoin();

        vm.prank(resolver1);
        board.castVote(disputeId, true);
        vm.prank(resolver2);
        board.castVote(disputeId, false);

        // 1-1, still open; third vote decides.
        SweeftDisputeBoard.DisputeState stateAfterTwo;
        (,,,, stateAfterTwo,,,,,) = board.getDispute(disputeId);
        assertEq(uint8(stateAfterTwo), uint8(SweeftDisputeBoard.DisputeState.Open));

        vm.prank(resolver3);
        board.castVote(disputeId, false); // 2-1 refund

        bool releaseToSeller;
        SweeftDisputeBoard.DisputeState finalState;
        (,,,, finalState, releaseToSeller,,,,) = board.getDispute(disputeId);
        assertEq(uint8(finalState), uint8(SweeftDisputeBoard.DisputeState.Resolved));
        assertFalse(releaseToSeller);
    }

    function test_Vote_NonMemberRejected() public {
        (, uint256 disputeId) = _openDispute();
        vm.prank(resolver1);
        vm.expectRevert(SweeftDisputeBoard.NotMember.selector);
        board.castVote(disputeId, true);
    }

    function test_Vote_OnceOnly() public {
        (, uint256 disputeId) = _openAndJoin();
        vm.prank(resolver1);
        board.castVote(disputeId, true);
        vm.prank(resolver1);
        vm.expectRevert(SweeftDisputeBoard.AlreadyVoted.selector);
        board.castVote(disputeId, true);
    }

    function test_Vote_AfterDeadlineRejected() public {
        (, uint256 disputeId) = _openAndJoin();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(resolver1);
        vm.expectRevert(SweeftDisputeBoard.VotingClosed.selector);
        board.castVote(disputeId, true);
    }

    function test_ResolveExpired_OwnerFallback() public {
        (, uint256 disputeId) = _openAndJoin();

        vm.expectRevert(SweeftDisputeBoard.VotingStillOpen.selector);
        board.resolveExpired(disputeId, false);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 buyerBefore = buyer.balance;
        board.resolveExpired(disputeId, false);
        assertEq(buyer.balance, buyerBefore + AMOUNT);
    }

    function test_ResolveExpired_OnlyOwner() public {
        (, uint256 disputeId) = _openAndJoin();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(resolver1);
        vm.expectRevert(SweeftDisputeBoard.NotOwner.selector);
        board.resolveExpired(disputeId, false);
    }

    // ------------------------------------------------------------------
    // Rewards
    // ------------------------------------------------------------------

    function test_ClaimReward_VotersGetTenthOfFeeEach() public {
        (, uint256 disputeId) = _openAndJoin();

        vm.prank(resolver1);
        board.castVote(disputeId, true);
        vm.prank(resolver2);
        board.castVote(disputeId, true);

        uint256 fee = (AMOUNT * FEE_BPS) / 10_000; // 0.02 ether
        uint256 expected = (fee * 3000) / 10_000 / 3; // 10% of fee = 0.002 ether

        uint256 r1Before = resolver1.balance;
        vm.prank(resolver1);
        board.claimReward(disputeId);
        assertEq(resolver1.balance, r1Before + expected);

        uint256 r2Before = resolver2.balance;
        vm.prank(resolver2);
        board.claimReward(disputeId);
        assertEq(resolver2.balance, r2Before + expected);

        // Non-voting member cannot claim.
        vm.prank(resolver3);
        vm.expectRevert(SweeftDisputeBoard.NotMember.selector);
        board.claimReward(disputeId);

        // Double claim rejected.
        vm.prank(resolver1);
        vm.expectRevert(SweeftDisputeBoard.AlreadyVoted.selector);
        board.claimReward(disputeId);
    }

    function test_ClaimReward_FromPoolOnly_StakesSafe() public {
        // A refund dispute pays resolvers from the accumulated pool, never
        // from staked funds.
        (uint256 escrowId, uint256 disputeId) = _openAndJoin();
        escrowId;

        vm.prank(resolver1);
        board.castVote(disputeId, false);
        vm.prank(resolver2);
        board.castVote(disputeId, false);

        // Pool is empty (no fee on refunds) — claim reverts; stakes untouched.
        uint256 stakesTotal = 80 ether;
        assertEq(board.rewardPool(), 0);
        vm.prank(resolver1);
        vm.expectRevert(SweeftDisputeBoard.TransferFailed.selector);
        board.claimReward(disputeId);

        // Stakers can still withdraw their full stake.
        vm.prank(resolver4);
        board.requestUnstake();
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 before = resolver4.balance;
        vm.prank(resolver4);
        board.withdrawStake();
        assertEq(resolver4.balance, before + 20 ether);
        stakesTotal; // silence warning
    }

    function test_Resolvers_ReleasedFromBoard_AfterSettle() public {
        (, uint256 disputeId) = _openAndJoin();
        assertEq(board.activeBoards(resolver1), 1);

        vm.prank(resolver1);
        board.castVote(disputeId, true);
        vm.prank(resolver2);
        board.castVote(disputeId, true);

        assertEq(board.activeBoards(resolver1), 0);
        assertEq(board.activeBoards(resolver2), 0);

        vm.prank(resolver1);
        board.requestUnstake(); // no longer blocked
    }
}
