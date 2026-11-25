// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SweeftDAO2 } from "../src/SweeftDAO2.sol";
import { SweeftOracleRegistry } from "../src/SweeftOracleRegistry.sol";

/// @notice DAO governance regression suite. Voting periods are bounded, only
///         allowlisted (target, selector) pairs may be called, quorum is
///         measured in escrowed stake, a timelock and proposer bond apply, a
///         guardian may veto during the timelock, and vote stake is locked
///         until the proposal is final.
contract SweeftDAO2Test is Test {
    SweeftOracleRegistry internal registry;
    SweeftDAO2 internal dao;

    address internal proposer = address(0xF00D);
    address internal voterA = address(0xA1);
    address internal voterB = address(0xB2);
    address internal voterC = address(0xC3);
    address internal voterD = address(0xD4);
    address internal attacker = address(0xBAD);
    address internal newVerifier = address(0xACE);
    address internal treasury = address(0x7EA5);

    uint64 internal constant PERIOD = 3 days; // == MIN_VOTING_PERIOD
    uint256 internal constant VOTE = 0.01 ether;
    bytes4 internal constant ADD_VERIFIER = bytes4(keccak256("addVerifier(address)"));

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        address[] memory targets = new address[](1);
        targets[0] = address(registry);
        dao = new SweeftDAO2(targets);
        // Allow only the specific privileged call; everything else is denied.
        dao.setAllowedCall(address(registry), ADD_VERIFIER, true);
        dao.setTreasury(treasury);
        registry.transferOwnership(address(dao));

        vm.deal(proposer, 10 ether);
        vm.deal(voterA, 10 ether);
        vm.deal(voterB, 10 ether);
        vm.deal(voterC, 10 ether);
        vm.deal(voterD, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    function _callData() internal view returns (bytes memory) {
        return abi.encodeWithSignature("addVerifier(address)", newVerifier);
    }

    function _propose(uint64 period) internal returns (uint256) {
        vm.prank(proposer);
        return dao.propose{ value: 0.05 ether }(
            address(registry), _callData(), "Approve verifier 0xACE", "Adds 0xACE as an oracle verifier", period
        );
    }

    function _vote(address voter, uint256 id, uint8 choice, uint256 stake) internal {
        vm.prank(voter);
        dao.castVote{ value: stake }(id, choice);
    }

    function _threeForVotes(uint256 id) internal {
        _vote(voterA, id, 1, VOTE);
        _vote(voterB, id, 1, VOTE);
        _vote(voterC, id, 1, VOTE);
    }

    // ------------------------------------------------------------------
    // Period bounds
    // ------------------------------------------------------------------

    function test_Propose_RejectsTooShortPeriod() public {
        vm.prank(proposer);
        vm.expectRevert(SweeftDAO2.BadVotingPeriod.selector);
        dao.propose{ value: 0.05 ether }(address(registry), _callData(), "t", "d", 1 hours);
    }

    function test_Propose_RejectsTooLongPeriod() public {
        vm.prank(proposer);
        vm.expectRevert(SweeftDAO2.BadVotingPeriod.selector);
        dao.propose{ value: 0.05 ether }(address(registry), _callData(), "t", "d", 60 days);
    }

    // ------------------------------------------------------------------
    // Allowlist + bond
    // ------------------------------------------------------------------

    function test_Propose_RejectsDisallowedSelector() public {
        bytes memory evil = abi.encodeWithSignature("removeVerifier(address)", address(0x1));
        vm.prank(proposer);
        vm.expectRevert(SweeftDAO2.CallNotAllowed.selector);
        dao.propose{ value: 0.05 ether }(address(registry), evil, "t", "d", PERIOD);
    }

    function test_Propose_RejectsUnlistedTarget() public {
        vm.prank(proposer);
        vm.expectRevert(SweeftDAO2.TargetNotAllowed.selector);
        dao.propose{ value: 0.05 ether }(address(0xDEAD), _callData(), "t", "d", PERIOD);
    }

    function test_Propose_RequiresBond() public {
        vm.prank(proposer);
        vm.expectRevert(SweeftDAO2.WrongBond.selector);
        dao.propose(address(registry), _callData(), "t", "d", PERIOD);
    }

    // ------------------------------------------------------------------
    // Quorum + timelock
    // ------------------------------------------------------------------

    function test_Execute_RequiresTimelock() public {
        uint256 id = _propose(PERIOD);
        _threeForVotes(id);

        // Voting closed, but the timelock has not elapsed.
        vm.warp(block.timestamp + PERIOD + 1);
        vm.expectRevert(SweeftDAO2.TimelockActive.selector);
        dao.execute(id, "Adds 0xACE as an oracle verifier");
    }

    function test_Execute_QuorumNotMet_Rejects() public {
        uint256 id = _propose(PERIOD);
        // Only one minimum stake — below the 0.03 QOR quorum.
        _vote(attacker, id, 1, VOTE);

        vm.warp(block.timestamp + PERIOD + 2 days + 1);
        dao.execute(id, "Adds 0xACE as an oracle verifier");

        assertFalse(registry.isVerifier(newVerifier));
        assertEq(uint8(dao.getProposal(id).state), uint8(SweeftDAO2.ProposalState.Rejected));
    }

    function test_Execute_WithQuorumAndTimelock_Succeeds() public {
        uint256 id = _propose(PERIOD);
        _threeForVotes(id);

        uint256 proposerBefore = proposer.balance;
        vm.warp(block.timestamp + PERIOD + 2 days + 1);
        dao.execute(id, "Adds 0xACE as an oracle verifier");

        assertTrue(registry.isVerifier(newVerifier));
        // Bond refunded on success.
        assertEq(proposer.balance, proposerBefore + 0.05 ether);
    }

    function test_CriticalQuorum_RequiresMoreStake() public {
        // Mark the registry call critical: it now needs 0.05 QOR, not 0.03.
        dao.setCriticalCall(address(registry), ADD_VERIFIER, true);

        uint256 id = _propose(PERIOD);
        _threeForVotes(id); // 0.03 < critical 0.05
        vm.warp(block.timestamp + PERIOD + 2 days + 1);
        dao.execute(id, "Adds 0xACE as an oracle verifier");
        assertFalse(registry.isVerifier(newVerifier));
        assertEq(uint8(dao.getProposal(id).state), uint8(SweeftDAO2.ProposalState.Rejected));

        // A second proposal with 0.05 of stake passes.
        uint256 id2 = _propose(PERIOD);
        _vote(voterA, id2, 1, 0.05 ether);
        vm.warp(block.timestamp + PERIOD + 2 days + 1);
        dao.execute(id2, "Adds 0xACE as an oracle verifier");
        assertTrue(registry.isVerifier(newVerifier));
    }

    function test_ShortWindowTakeover_NowImpossible() public {
        // The attack the review described: a 1-second window with throwaway
        // voters. It now reverts at propose().
        vm.prank(attacker);
        vm.expectRevert(SweeftDAO2.BadVotingPeriod.selector);
        dao.propose{ value: 0.05 ether }(address(registry), _callData(), "seize", "seize", 1);
    }

    // ------------------------------------------------------------------
    // Vote stake (Sybil cost)
    // ------------------------------------------------------------------

    function test_CastVote_RequiresStake() public {
        uint256 id = _propose(PERIOD);
        vm.prank(voterA);
        vm.expectRevert(SweeftDAO2.VoteStakeTooLow.selector);
        dao.castVote(id, 1);
    }

    function test_VoteStake_LockedUntilFinal_ThenWithdrawable() public {
        uint256 id = _propose(PERIOD);
        _vote(voterA, id, 1, VOTE);
        _vote(voterB, id, 1, VOTE);
        _vote(voterC, id, 1, VOTE);

        vm.prank(voterA);
        vm.expectRevert(SweeftDAO2.VoteStakeLocked.selector);
        dao.withdrawVoteStake(id);

        vm.warp(block.timestamp + PERIOD + 2 days + 1);
        dao.execute(id, "Adds 0xACE as an oracle verifier");

        uint256 before = voterA.balance;
        vm.prank(voterA);
        dao.withdrawVoteStake(id);
        assertEq(voterA.balance, before + VOTE);
    }

    function test_SybilVotersMustLockCapital() public {
        uint256 id = _propose(PERIOD);
        address[3] memory sybils = [address(0x1001), address(0x1002), address(0x1003)];
        for (uint256 i = 0; i < sybils.length; i++) {
            vm.deal(sybils[i], VOTE);
            _vote(sybils[i], id, 1, VOTE);
            // The full stake is held by the DAO, not refunded on success.
            assertEq(sybils[i].balance, 0);
        }
        assertEq(address(dao).balance, 3 * VOTE + 0.05 ether);
    }

    // ------------------------------------------------------------------
    // Vote hygiene / lifecycle
    // ------------------------------------------------------------------

    function test_CastVote_RejectsBadChoice() public {
        uint256 id = _propose(PERIOD);
        vm.prank(voterA);
        vm.expectRevert(SweeftDAO2.BadChoice.selector);
        dao.castVote{ value: VOTE }(id, 9);
    }

    function test_MinVoteStake_Enforced() public {
        dao.setMinVoteStake(0.02 ether);
        uint256 id = _propose(PERIOD);

        vm.prank(voterA);
        vm.expectRevert(SweeftDAO2.VoteStakeTooLow.selector);
        dao.castVote{ value: 0.01 ether }(id, 1);

        // A vote at the new minimum passes the gate.
        _vote(voterB, id, 1, 0.02 ether);
        assertTrue(dao.hasVoted(id, voterB));
    }

    function test_GuardianVeto_DuringTimelock() public {
        uint256 id = _propose(PERIOD);
        _threeForVotes(id);
        vm.warp(block.timestamp + PERIOD + 1);

        uint256 treasuryBefore = treasury.balance;
        // The test contract is the initial guardian.
        dao.veto(id);

        assertEq(uint8(dao.getProposal(id).state), uint8(SweeftDAO2.ProposalState.Vetoed));
        assertEq(treasury.balance, treasuryBefore + 0.05 ether);
    }

    function test_Cancel_RefundsBond_AndUnlocksVoters() public {
        uint256 id = _propose(PERIOD);
        _vote(voterA, id, 1, VOTE);

        uint256 proposerBefore = proposer.balance;
        vm.prank(proposer);
        dao.cancel(id);

        assertEq(uint8(dao.getProposal(id).state), uint8(SweeftDAO2.ProposalState.Cancelled));
        assertEq(proposer.balance, proposerBefore + 0.05 ether);

        // Vote stake is unlocked by cancellation.
        uint256 voterBefore = voterA.balance;
        vm.prank(voterA);
        dao.withdrawVoteStake(id);
        assertEq(voterA.balance, voterBefore + VOTE);
    }

    function test_Expire_AfterTTL_UnlocksVoters() public {
        uint256 id = _propose(PERIOD);
        _vote(voterA, id, 1, VOTE);

        vm.warp(block.timestamp + PERIOD + 2 days + 30 days + 1);
        dao.expireProposal(id);
        assertEq(uint8(dao.getProposal(id).state), uint8(SweeftDAO2.ProposalState.Expired));

        uint256 voterBefore = voterA.balance;
        vm.prank(voterA);
        dao.withdrawVoteStake(id);
        assertEq(voterA.balance, voterBefore + VOTE);
    }
}
