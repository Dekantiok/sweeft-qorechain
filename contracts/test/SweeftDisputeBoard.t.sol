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
    address internal carrier = address(0xCA99);
    address internal treasury = address(0x7EA5);

    uint256 internal constant AMOUNT = 1 ether;
    uint256 internal constant FEE_BPS = 200;
    uint256 internal constant BOND = 0.1 ether;
    uint256 internal constant STAKE = 21 ether; // >= 20 + 1% of AMOUNT

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        vault = new SweeftVault(address(registry), "qorechain-diana", FEE_BPS, treasury);
        board = new SweeftDisputeBoard(address(vault));
        vault.setDisputeBoard(address(board));
        board.setVotingPeriod(1 hours);
        board.setUnstakeCooldown(1 hours);

        // Etch PQ precompile mocks; the vault now requires a registered key
        // for the buyer at escrow creation.
        MockKS ks = new MockKS();
        MockPV pv = new MockPV();
        vm.etch(0x0000000000000000000000000000000000000a02, address(ks).code);
        vm.etch(0x0000000000000000000000000000000000000a01, address(pv).code);
        MockKS(0x0000000000000000000000000000000000000a02).setRegistered(buyer, true, true);
        MockPV(0x0000000000000000000000000000000000000a01).setResult(true);

        address[4] memory resolvers = [resolver1, resolver2, resolver3, resolver4];
        for (uint256 i = 0; i < resolvers.length; i++) {
            vm.deal(resolvers[i], 30 ether);
            vm.prank(resolvers[i]);
            board.stake{ value: STAKE }();
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _fundedEscrow() internal returns (uint256) {
        vm.deal(buyer, AMOUNT);
        vm.prank(buyer);
        uint256 id = vault.createEscrow(buyer, seller, uint64(block.timestamp + 7 days), AMOUNT);
        vm.prank(buyer);
        vault.fundEscrow{ value: AMOUNT }(id);
        return id;
    }

    function _openDispute() internal returns (uint256 escrowId, uint256 disputeId) {
        escrowId = _fundedEscrow();
        vm.deal(buyer, BOND);
        vm.prank(buyer);
        disputeId = board.openDispute{ value: BOND }(escrowId);
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

    function test_MinStakeFor_ScalesWithEscrow() public {
        assertEq(board.minStakeFor(1 ether), 20 ether + 0.01 ether);
        assertEq(board.minStakeFor(100 ether), 20 ether + 1 ether);
    }

    // ------------------------------------------------------------------
    // Dispute lifecycle
    // ------------------------------------------------------------------

    function test_OpenDispute_ByBuyer_FreezesEscrow() public {
        uint256 escrowId = _fundedEscrow();

        vm.deal(buyer, BOND);
        vm.prank(buyer);
        uint256 disputeId = board.openDispute{ value: BOND }(escrowId);

        SweeftVault.Escrow memory e = vault.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(SweeftVault.EscrowStatus.Disputed));
        assertFalse(vault.isReleaseEligible(escrowId));
        assertFalse(vault.isRefundable(escrowId));

        (uint256 storedEscrow,,,,,,,,,,,) = board.getDispute(disputeId);
        assertEq(storedEscrow, escrowId);
    }

    function test_OpenDispute_BySeller() public {
        uint256 escrowId = _fundedEscrow();
        vm.deal(seller, BOND);
        vm.prank(seller);
        board.openDispute{ value: BOND }(escrowId);
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Disputed));
    }

    function test_OpenDispute_RequiresBond() public {
        uint256 escrowId = _fundedEscrow();
        vm.deal(buyer, 0.05 ether);
        vm.prank(buyer);
        vm.expectRevert(SweeftDisputeBoard.BondTooLow.selector);
        board.openDispute{ value: 0.05 ether }(escrowId);
    }

    function test_OpenDispute_StrangerRejected() public {
        uint256 escrowId = _fundedEscrow();
        vm.deal(address(0xCAFE), BOND);
        vm.prank(address(0xCAFE));
        vm.expectRevert(SweeftDisputeBoard.ExcludedParty.selector);
        board.openDispute{ value: BOND }(escrowId);
    }

    function test_OpenDispute_OutsideVaultPath() public {
        uint256 escrowId = _fundedEscrow();
        vm.prank(buyer);
        vault.raiseDispute(escrowId);

        vm.deal(seller, BOND);
        vm.prank(seller);
        vm.expectRevert(SweeftVault.NotDisputable.selector);
        board.openDispute{ value: BOND }(escrowId);
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

        vm.deal(buyer, 25 ether);
        vm.prank(buyer);
        board.stake{ value: 21 ether }();
        vm.deal(seller, 25 ether);
        vm.prank(seller);
        board.stake{ value: 21 ether }();

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

        vm.deal(buyer, BOND);
        vm.prank(buyer);
        uint256 disputeId = board.openDispute{ value: BOND }(escrowId);

        vm.deal(verifier, 25 ether);
        vm.prank(verifier);
        board.stake{ value: 21 ether }();

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
        // Pool gains the 30% dispute share plus the losing raiser's bond.
        assertEq(board.rewardPool(), boardBefore + (fee * 3000) / 10_000 + BOND);

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

        // Full refund of the escrow; the bond is returned too (buyer prevailed).
        assertEq(buyer.balance, buyerBefore + AMOUNT + BOND);
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Refunded));
    }

    function test_Vote_SplitThenFinish() public {
        (, uint256 disputeId) = _openAndJoin();

        vm.prank(resolver1);
        board.castVote(disputeId, true);
        vm.prank(resolver2);
        board.castVote(disputeId, false);

        (,,,,, SweeftDisputeBoard.DisputeState stateAfterTwo,,,,,,) = board.getDispute(disputeId);
        assertEq(uint8(stateAfterTwo), uint8(SweeftDisputeBoard.DisputeState.Open));

        vm.prank(resolver3);
        board.castVote(disputeId, false); // 2-1 refund

        bool releaseToSeller;
        SweeftDisputeBoard.DisputeState finalState;
        (,,,,, finalState, releaseToSeller, , , , , ) = board.getDispute(disputeId);
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

    // ------------------------------------------------------------------
    // Expiry (deterministic, permissionless)
    // ------------------------------------------------------------------

    function test_ResolveExpired_DeterministicRefundWhenUndelivered() public {
        (uint256 escrowId, uint256 disputeId) = _openAndJoin();

        vm.expectRevert(SweeftDisputeBoard.VotingStillOpen.selector);
        board.resolveExpired(disputeId);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 buyerBefore = buyer.balance;
        // Anyone may call it — no owner privilege.
        vm.prank(resolver1);
        board.resolveExpired(disputeId);
        assertEq(buyer.balance, buyerBefore + AMOUNT + BOND);
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Refunded));
    }

    function test_ResolveExpired_ReleasesWhenDelivered() public {
        // Seller marks delivered before the dispute; expiry must release.
        vm.deal(buyer, AMOUNT);
        vm.prank(buyer);
        uint256 escrowId = vault.createEscrow(buyer, seller, uint64(block.timestamp + 7 days), AMOUNT);
        vm.prank(buyer);
        vault.fundEscrow{ value: AMOUNT }(escrowId);
        vm.prank(seller);
        vault.markDelivered(escrowId);

        vm.deal(buyer, BOND);
        vm.prank(buyer);
        uint256 disputeId = board.openDispute{ value: BOND }(escrowId);

        vm.warp(block.timestamp + 1 hours + 1);
        board.resolveExpired(disputeId);
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Completed));
    }

    // ------------------------------------------------------------------
    // Rewards
    // ------------------------------------------------------------------

    function test_ClaimReward_VotersGetShare() public {
        (, uint256 disputeId) = _openAndJoin();

        vm.prank(resolver1);
        board.castVote(disputeId, true);
        vm.prank(resolver2);
        board.castVote(disputeId, true);

        uint256 fee = (AMOUNT * FEE_BPS) / 10_000; // 0.02 ether
        uint256 expected = (fee * 3000) / 10_000 / 2; // 30% share / 2 voters

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

    function test_ClaimReward_RefundPaysNothing() public {
        (, uint256 disputeId) = _openAndJoin();

        vm.prank(resolver1);
        board.castVote(disputeId, false);
        vm.prank(resolver2);
        board.castVote(disputeId, false);

        // A refund collects no fee, so there is no resolver reward.
        assertEq(board.resolverReward(disputeId), 0);
        vm.prank(resolver1);
        vm.expectRevert(SweeftDisputeBoard.NoStake.selector);
        board.claimReward(disputeId);
    }

    // ------------------------------------------------------------------
    // Slashing
    // ------------------------------------------------------------------

    function test_Slash_MinorityVoter() public {
        (, uint256 disputeId) = _openAndJoin();
        uint256 stakeBefore = board.stakeOf(resolver2);

        vm.prank(resolver1);
        board.castVote(disputeId, true);
        vm.prank(resolver2);
        board.castVote(disputeId, false); // minority
        vm.prank(resolver3);
        board.castVote(disputeId, true); // 2-1 release

        uint256 slash = (stakeBefore * 1000) / 10_000; // 10%
        assertEq(board.stakeOf(resolver2), stakeBefore - slash);
        assertEq(board.stakeOf(resolver1), stakeBefore); // majority untouched
    }

    function test_NoSlash_NonVoterOnEarlySettle() public {
        (, uint256 disputeId) = _openAndJoin();
        uint256 stakeBefore = board.stakeOf(resolver3);

        // Settlement happens on the second vote; resolver3 never gets a turn.
        vm.prank(resolver1);
        board.castVote(disputeId, true);
        vm.prank(resolver2);
        board.castVote(disputeId, true);

        assertEq(board.stakeOf(resolver3), stakeBefore);
    }

    function test_Slash_NonVotersOnExpiry() public {
        (, uint256 disputeId) = _openAndJoin();
        uint256 stakeBefore = board.stakeOf(resolver1);

        vm.warp(block.timestamp + 1 hours + 1);
        board.resolveExpired(disputeId);

        uint256 slash = (stakeBefore * 1000) / 10_000;
        assertEq(board.stakeOf(resolver1), stakeBefore - slash);
    }

    // ------------------------------------------------------------------
    // Locks
    // ------------------------------------------------------------------

    function test_Resolvers_LockedThroughAppealWindow() public {
        (, uint256 disputeId) = _openAndJoin();

        vm.prank(resolver1);
        board.castVote(disputeId, true);
        vm.prank(resolver2);
        board.castVote(disputeId, true);

        // Still locked immediately after settlement.
        vm.prank(resolver1);
        vm.expectRevert(SweeftDisputeBoard.StakeLocked.selector);
        board.requestUnstake();

        // After the voting period plus the appeal window, the lock lifts.
        vm.warp(block.timestamp + 1 hours + 1 days + 1);
        vm.prank(resolver1);
        board.requestUnstake();
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
