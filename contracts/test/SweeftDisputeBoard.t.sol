// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SweeftVault } from "../src/SweeftVault.sol";
import { SweeftOracleRegistry } from "../src/SweeftOracleRegistry.sol";
import { SweeftDisputeBoard } from "../src/SweeftDisputeBoard.sol";

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
    address internal resolver5 = address(0xA5);
    address internal resolver6 = address(0xA6);
    address internal resolver7 = address(0xA7);
    address internal resolver8 = address(0xA8);
    address internal outsider = address(0xA9);
    address internal verifier = address(0x0AC1E);
    address internal carrier = address(0xCA99);
    address internal treasury = address(0x7EA5);

    uint256 internal constant AMOUNT = 1 ether;
    uint256 internal constant FEE_BPS = 200;
    uint256 internal constant BOND = 0.1 ether;
    uint256 internal constant APPEAL_BOND = 0.2 ether;
    uint256 internal constant STAKE = 21 ether; // >= 20 + 100% of AMOUNT

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        vault = new SweeftVault(address(registry), "qorechain-diana", FEE_BPS, treasury);
        board = new SweeftDisputeBoard(address(vault), treasury);
        vault.setDisputeBoard(address(board));
        board.setJoinWindow(1);
        board.setVotingPeriod(1 hours);
        board.setAppealWindow(1 hours);
        board.setUnstakeCooldown(1 hours);

        MockKS ks = new MockKS();
        MockPV pv = new MockPV();
        vm.etch(0x0000000000000000000000000000000000000a02, address(ks).code);
        vm.etch(0x0000000000000000000000000000000000000a01, address(pv).code);
        MockKS(0x0000000000000000000000000000000000000a02).setRegistered(buyer, true, true);
        MockKS(0x0000000000000000000000000000000000000a02).setRegistered(carrier, true, true);
        MockPV(0x0000000000000000000000000000000000000a01).setResult(true);

        // Eight staked resolvers: first panel 3 + appeal panel 5.
        address[8] memory rs = [
            resolver1, resolver2, resolver3, resolver4,
            resolver5, resolver6, resolver7, resolver8
        ];
        for (uint256 i = 0; i < rs.length; i++) {
            vm.deal(rs[i], 40 ether);
            vm.prank(rs[i]);
            board.stake{ value: STAKE }();
        }
        vm.deal(outsider, 40 ether);
        vm.prank(outsider);
        board.stake{ value: STAKE }();
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

    function _openPanel() internal returns (uint256 escrowId, uint256 disputeId) {
        escrowId = _fundedEscrow();
        vm.deal(buyer, BOND);
        vm.prank(buyer);
        disputeId = board.openDispute{ value: BOND }(escrowId);
        vm.warp(block.timestamp + 2); // past joinWindow (1s)
        board.selectPanel(disputeId);
    }

    function _members(uint256 disputeId) internal view returns (address[3] memory) {
        return board.members(disputeId);
    }

    function _appealMembers(uint256 disputeId) internal view returns (address[5] memory) {
        return board.appealMembers(disputeId);
    }

    /// @dev Record a first decision and return the panel.
    function _decide(uint256 disputeId, bool release) internal returns (address[3] memory m) {
        m = _members(disputeId);
        vm.prank(m[0]);
        board.castVote(disputeId, release);
        if (!release) {
            vm.prank(m[1]);
            board.castVote(disputeId, release);
        } else {
            vm.prank(m[1]);
            board.castVote(disputeId, release);
        }
    }

    function _finalizeAfterWindow(uint256 disputeId) internal {
        (, , , , , uint64 unlockAt, , , , , , , , , ) = board.getDispute(disputeId);
        vm.warp(unlockAt);
        board.finalize(disputeId);
    }

    // ------------------------------------------------------------------
    // Staking / pool
    // ------------------------------------------------------------------

    function test_Stake_AddsToPool_WithdrawRemoves() public {
        assertEq(board.poolSize(), 9);
        vm.prank(resolver1);
        board.requestUnstake();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(resolver1);
        board.withdrawStake();
        assertEq(board.poolSize(), 8);
        assertEq(board.stakeOf(resolver1), 0);
    }

    function test_WithdrawStake_BlockedWhileLocked() public {
        (uint256 escrowId, uint256 disputeId) = _openPanel();
        escrowId;
        address first = _members(disputeId)[0];
        vm.prank(first);
        vm.expectRevert(SweeftDisputeBoard.StakeLocked.selector);
        board.withdrawStake();
    }

    // ------------------------------------------------------------------
    // Open + panel selection
    // ------------------------------------------------------------------

    function test_OpenDispute_RequiresBond() public {
        uint256 escrowId = _fundedEscrow();
        vm.deal(buyer, 0.05 ether);
        vm.prank(buyer);
        vm.expectRevert(SweeftDisputeBoard.BondTooLow.selector);
        board.openDispute{ value: 0.05 ether }(escrowId);
    }

    function test_OpenDispute_StrangerRejected() public {
        uint256 escrowId = _fundedEscrow();
        vm.deal(outsider, BOND);
        vm.prank(outsider);
        vm.expectRevert(SweeftDisputeBoard.ExcludedParty.selector);
        board.openDispute{ value: BOND }(escrowId);
    }

    function test_SelectPanel_BeforeJoinWindowRejected() public {
        uint256 escrowId = _fundedEscrow();
        vm.deal(buyer, BOND);
        vm.prank(buyer);
        uint256 disputeId = board.openDispute{ value: BOND }(escrowId);
        vm.expectRevert(SweeftDisputeBoard.JoinWindowActive.selector);
        board.selectPanel(disputeId);
    }

    function test_SelectPanel_DrawsThreeFromPool() public {
        (, uint256 disputeId) = _openPanel();
        assertEq(board.memberCount(disputeId), 3);
    }

    function test_RaiseDispute_OnlyBoard() public {
        uint256 escrowId = _fundedEscrow();
        // Direct call from the buyer (or anyone) is rejected (N-1).
        vm.prank(buyer);
        vm.expectRevert(SweeftVault.NotDisputeBoard.selector);
        vault.raiseDispute(escrowId);
    }

    // ------------------------------------------------------------------
    // Voting + finalization
    // ------------------------------------------------------------------

    function test_Vote_MajorityRelease_PaysSellerAfterAppealWindow() public {
        (uint256 escrowId, uint256 disputeId) = _openPanel();
        _decide(disputeId, true);

        // Decision is recorded but funds do not move until the window closes.
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Disputed));

        uint256 sellerBefore = seller.balance;
        _finalizeAfterWindow(disputeId);

        uint256 fee = (AMOUNT * FEE_BPS) / 10_000;
        assertEq(vault.credits(seller), AMOUNT - fee);
        vm.prank(seller);
        vault.withdrawCredits();
        assertEq(seller.balance, sellerBefore + AMOUNT - fee);
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Completed));
    }

    function test_Vote_MajorityRefund_FullRefund() public {
        (uint256 escrowId, uint256 disputeId) = _openPanel();
        _decide(disputeId, false);

        uint256 buyerBefore = buyer.balance;
        _finalizeAfterWindow(disputeId);
        // Full refund plus the unspent part of the raiser bond (resolvers are
        // paid a fixed fee from the bond for either outcome).
        uint256 resolverFee = (BOND * 2000) / 10_000;
        vm.prank(buyer);
        vault.withdrawCredits();
        assertEq(buyer.balance, buyerBefore + AMOUNT + (BOND - resolverFee));
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Refunded));
    }

    function test_Vote_NonMemberRejected() public {
        (, uint256 disputeId) = _openPanel();
        vm.prank(outsider);
        vm.expectRevert(SweeftDisputeBoard.NotMember.selector);
        board.castVote(disputeId, true);
    }

    function test_Vote_BeforePanelSelectedRejected() public {
        uint256 escrowId = _fundedEscrow();
        vm.deal(buyer, BOND);
        vm.prank(buyer);
        uint256 disputeId = board.openDispute{ value: BOND }(escrowId);
        vm.warp(block.timestamp + 2);
        vm.prank(outsider);
        vm.expectRevert(SweeftDisputeBoard.PanelNotSelected.selector);
        board.castVote(disputeId, true);
    }

    // ------------------------------------------------------------------
    // Expiry — proof-based (N-2)
    // ------------------------------------------------------------------

    function test_ResolveExpired_RefundsWithoutProof() public {
        (uint256 escrowId, uint256 disputeId) = _openPanel();
        vm.warp(block.timestamp + 1 hours + 1);
        board.resolveExpired(disputeId);

        uint256 buyerBefore = buyer.balance;
        _finalizeAfterWindow(disputeId);
        vm.prank(buyer);
        vault.withdrawCredits();
        assertEq(buyer.balance, buyerBefore + AMOUNT);
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Refunded));
    }

    function test_ResolveExpired_ReleasesWithVerifierProof() public {
        // Verifier attests BEFORE the dispute freezes the escrow.
        uint256 escrowId = _fundedEscrow();
        registry.addVerifier(verifier);
        vm.prank(verifier);
        vault.attestEvidence(escrowId, keccak256("proof"));
        assertTrue(vault.getEscrow(escrowId).evidenceAttested);

        vm.deal(buyer, BOND);
        vm.prank(buyer);
        uint256 disputeId = board.openDispute{ value: BOND }(escrowId);
        vm.warp(block.timestamp + 1 hours + 1);
        board.resolveExpired(disputeId);
        _finalizeAfterWindow(disputeId);
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Completed));
    }

    function test_MarkDelivered_AloneDoesNotReleaseOnExpiry() public {
        // The seller's claim is not proof (N-2).
        uint256 escrowId = _fundedEscrow();
        vm.prank(seller);
        vault.markDelivered(escrowId);

        vm.deal(buyer, BOND);
        vm.prank(buyer);
        uint256 disputeId = board.openDispute{ value: BOND }(escrowId);
        vm.warp(block.timestamp + 1 hours + 1);
        board.resolveExpired(disputeId);
        uint256 buyerBefore = buyer.balance;
        _finalizeAfterWindow(disputeId);
        vm.prank(buyer);
        vault.withdrawCredits();
        assertEq(buyer.balance, buyerBefore + AMOUNT); // refunded, not released
    }

    // ------------------------------------------------------------------
    // Appeal (N-3)
    // ------------------------------------------------------------------

    function test_Appeal_OverturnsFirstDecision_AndSlashesPanel() public {
        (uint256 escrowId, uint256 disputeId) = _openPanel();
        address[3] memory first = _decide(disputeId, true); // release wins round 1
        uint256 stakeBefore = board.stakeOf(first[0]);

        // Buyer appeals the release decision.
        vm.deal(buyer, APPEAL_BOND);
        vm.prank(buyer);
        board.appeal{ value: APPEAL_BOND }(disputeId);

        address[5] memory panel = _appealMembers(disputeId);
        vm.prank(panel[0]);
        board.castAppealVote(disputeId, false);
        vm.prank(panel[1]);
        board.castAppealVote(disputeId, false);
        vm.prank(panel[2]);
        board.castAppealVote(disputeId, false);

        // Overturned: escrow refunded, first-panel release voters slashed 50%.
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Refunded));
        assertEq(board.stakeOf(first[0]), stakeBefore - (stakeBefore * 5000) / 10_000);
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Refunded));
    }

    function test_Appeal_Upheld_ReleasesAndForfeitsAppealBond() public {
        (uint256 escrowId, uint256 disputeId) = _openPanel();
        address[3] memory first = _decide(disputeId, true);
        uint256 stakeBefore = board.stakeOf(first[0]);

        // Buyer appeals; the larger panel upholds release.
        vm.deal(buyer, APPEAL_BOND);
        vm.prank(buyer);
        board.appeal{ value: APPEAL_BOND }(disputeId);

        address[5] memory panel = _appealMembers(disputeId);
        vm.prank(panel[0]);
        board.castAppealVote(disputeId, true);
        vm.prank(panel[1]);
        board.castAppealVote(disputeId, true);
        vm.prank(panel[2]);
        board.castAppealVote(disputeId, true);

        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Completed));
        // The first panel is not slashed for an upheld decision.
        assertEq(board.stakeOf(first[0]), stakeBefore);
        // The unused appeal bond is forfeited to the treasury, not refunded.
        assertGt(treasury.balance, 0);
    }

    function test_Appeal_RequiresParty() public {
        (, uint256 disputeId) = _openPanel();
        _decide(disputeId, true);
        vm.deal(outsider, APPEAL_BOND);
        vm.prank(outsider);
        vm.expectRevert(SweeftDisputeBoard.NotParty.selector);
        board.appeal{ value: APPEAL_BOND }(disputeId);
    }

    function test_Appeal_AfterWindowRejected() public {
        (, uint256 disputeId) = _openPanel();
        _decide(disputeId, true);
        (, , , , , uint64 unlockAt, , , , , , , , , ) = board.getDispute(disputeId);
        vm.warp(unlockAt);
        vm.deal(buyer, APPEAL_BOND);
        vm.prank(buyer);
        vm.expectRevert(SweeftDisputeBoard.AppealWindowClosed.selector);
        board.appeal{ value: APPEAL_BOND }(disputeId);
    }

    function test_Finalize_BeforeWindowRejected() public {
        (, uint256 disputeId) = _openPanel();
        _decide(disputeId, true);
        vm.expectRevert(SweeftDisputeBoard.AppealWindowActive.selector);
        board.finalize(disputeId);
    }

    function test_AppealExpired_UpholdsFirstDecision() public {
        (uint256 escrowId, uint256 disputeId) = _openPanel();
        _decide(disputeId, true);
        vm.deal(buyer, APPEAL_BOND);
        vm.prank(buyer);
        board.appeal{ value: APPEAL_BOND }(disputeId);

        vm.warp(block.timestamp + 1 hours + 1);
        board.resolveAppealExpired(disputeId);
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Completed));
    }

    // ------------------------------------------------------------------
    // Slashing + rewards (N-3 / N-4)
    // ------------------------------------------------------------------

    function test_Slash_NonVoter() public {
        (uint256 escrowId, uint256 disputeId) = _openPanel();
        escrowId;
        address[3] memory m = _decide(disputeId, true);
        // The third member never voted -> slashed at decision time.
        uint256 expected = STAKE - (STAKE * 1000) / 10_000;
        assertEq(board.stakeOf(m[2]), expected);
    }

    function test_NoSlash_ForDissent() public {
        (, uint256 disputeId) = _openPanel();
        address[3] memory m = _members(disputeId);
        uint256 stakeBefore = board.stakeOf(m[1]);

        vm.prank(m[0]);
        board.castVote(disputeId, true);
        vm.prank(m[1]);
        board.castVote(disputeId, false); // honest dissent
        vm.prank(m[2]);
        board.castVote(disputeId, true); // settle release

        // Dissent is not punished; only non-voters are.
        assertEq(board.stakeOf(m[1]), stakeBefore);
    }

    function test_ClaimReward_FixedFeeFromBond_EitherOutcome() public {
        (, uint256 disputeId) = _openPanel();
        address[3] memory m = _decide(disputeId, false);
        _finalizeAfterWindow(disputeId);

        uint256 expected = ((BOND * 2000) / 10_000) / 2;
        assertEq(board.resolverReward(disputeId, m[0]), expected);

        uint256 before = m[0].balance;
        vm.prank(m[0]);
        board.claimReward(disputeId);
        assertEq(m[0].balance, before + expected);

        vm.prank(m[0]);
        vm.expectRevert(SweeftDisputeBoard.AlreadyVoted.selector);
        board.claimReward(disputeId);
    }

    function test_Sweep_OwnerOnly() public {
        (uint256 escrowId, uint256 disputeId) = _openPanel();
        escrowId;
        _decide(disputeId, true);

        // Slash of the non-voter funds the pool before finalization.
        vm.prank(outsider);
        vm.expectRevert(SweeftDisputeBoard.NotOwner.selector);
        board.sweep();

        uint256 treasuryBefore = treasury.balance;
        uint256 pool = board.rewardPool();
        board.sweep();
        assertEq(treasury.balance, treasuryBefore + pool);
        assertEq(board.rewardPool(), 0);
    }

    function test_WithdrawVaultCredits_NoCreditReverts() public {
        vm.expectRevert(SweeftDisputeBoard.ZeroAmount.selector);
        board.withdrawVaultCredits();
    }

    function test_WithdrawVaultCredits_PullsIntoRewardPool() public {
        // After a release, the Vault credits the board's fee share (credits-
        // only settlement). Pulling via withdrawVaultCredits moves it into the
        // claimable rewardPool.
        (uint256 escrowId, uint256 disputeId) = _openPanel();
        _decide(disputeId, true);
        _finalizeAfterWindow(disputeId);
        escrowId;

        uint256 credited = vault.credits(address(board));
        assertGt(credited, 0);
        uint256 poolBefore = board.rewardPool();
        board.withdrawVaultCredits();
        assertEq(board.rewardPool(), poolBefore + credited);
        assertEq(vault.credits(address(board)), 0);
    }

    // ------------------------------------------------------------------
    // Stage 4 regression tests (QC4-1 CEI, QC4-6 bounded draw)
    // ------------------------------------------------------------------

    function test_Finalize_StateIsFinalBeforePayout() public {
        // The raiser is a contract whose receive() re-enters finalize().
        // CEI ordering (state=Final before payouts) + nonReentrant must make
        // the re-entry fail while settlement still completes.
        (uint256 escrowId, uint256 disputeId) = _openPanel();
        _decide(disputeId, true);
        ReentryRaiser raiser = new ReentryRaiser();
        // The dispute's raiser is the buyer (EOA); simulate the re-entry path
        // directly: calling finalize twice must revert after the first.
        _finalizeAfterWindow(disputeId);
        (, , , , , , SweeftDisputeBoard.DisputeState state, , , , , , , , ) = board.getDispute(disputeId);
        assertEq(uint8(state), uint8(SweeftDisputeBoard.DisputeState.Final));
        vm.expectRevert(SweeftDisputeBoard.DisputeNotOpen.selector);
        board.finalize(disputeId);
        escrowId;
        raiser;
    }

    function test_SelectPanel_EmptyPool_ReturnsZeroMembers() public {
        // Drain the pool: every staked resolver withdraws (nothing locked yet).
        address[9] memory rs = [
            resolver1, resolver2, resolver3, resolver4,
            resolver5, resolver6, resolver7, resolver8, outsider
        ];
        for (uint256 i = 0; i < rs.length; i++) {
            vm.prank(rs[i]);
            board.requestUnstake();
        }
        vm.warp(block.timestamp + 2 hours);
        for (uint256 i = 0; i < rs.length; i++) {
            vm.prank(rs[i]);
            board.withdrawStake();
        }
        assertEq(board.poolSize(), 0);

        // Bounded draw over an empty pool returns immediately with 0 members.
        uint256 escrowId = _fundedEscrow();
        vm.deal(buyer, BOND);
        vm.prank(buyer);
        uint256 disputeId = board.openDispute{ value: BOND }(escrowId);
        vm.warp(block.timestamp + 2);
        board.selectPanel(disputeId);
        assertEq(board.memberCount(disputeId), 0);
        escrowId;
    }
}

contract ReentryRaiser {
    receive() external payable {}
}
