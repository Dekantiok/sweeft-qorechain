// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SweeftDAO2 } from "../src/SweeftDAO2.sol";
import { SweeftOracleRegistry } from "../src/SweeftOracleRegistry.sol";

/// @notice C-1 regression suite: governance cannot be seized by a short-window,
///         throwaway-wallet proposal. Voting periods are bounded, only
///         allowlisted (target, selector) pairs may be called, a quorum and a
///         timelock are enforced, and proposers post a bond.
contract SweeftDAO2Test is Test {
    SweeftOracleRegistry internal registry;
    SweeftDAO2 internal dao;

    address internal proposer = address(0xF00D);
    address internal voterA = address(0xA1);
    address internal voterB = address(0xB2);
    address internal voterC = address(0xC3);
    address internal attacker = address(0xBAD);
    address internal newVerifier = address(0xACE);

    uint64 internal constant PERIOD = 3 days; // == MIN_VOTING_PERIOD
    bytes4 internal constant ADD_VERIFIER = bytes4(keccak256("addVerifier(address)"));

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        address[] memory targets = new address[](1);
        targets[0] = address(registry);
        dao = new SweeftDAO2(targets);
        // Allow only the specific privileged call; everything else is denied.
        dao.setAllowedCall(address(registry), ADD_VERIFIER, true);
        registry.transferOwnership(address(dao));

        vm.deal(proposer, 10 ether);
        vm.deal(voterA, 10 ether);
        vm.deal(voterB, 10 ether);
        vm.deal(voterC, 10 ether);
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
        vm.prank(voterA);
        dao.castVote(id, 1);
        vm.prank(voterB);
        dao.castVote(id, 1);
        vm.prank(voterC);
        dao.castVote(id, 1);

        // Voting closed, but the timelock has not elapsed.
        vm.warp(block.timestamp + PERIOD + 1);
        vm.expectRevert(SweeftDAO2.TimelockActive.selector);
        dao.execute(id, "Adds 0xACE as an oracle verifier");
    }

    function test_Execute_QuorumNotMet_Rejects() public {
        uint256 id = _propose(PERIOD);
        // Only one vote — below quorum (3).
        vm.prank(attacker);
        dao.castVote(id, 1);

        vm.warp(block.timestamp + PERIOD + 2 days + 1);
        dao.execute(id, "Adds 0xACE as an oracle verifier");

        assertFalse(registry.isVerifier(newVerifier));
        assertEq(uint8(dao.getProposal(id).state), uint8(SweeftDAO2.ProposalState.Rejected));
    }

    function test_Execute_WithQuorumAndTimelock_Succeeds() public {
        uint256 id = _propose(PERIOD);
        vm.prank(voterA);
        dao.castVote(id, 1);
        vm.prank(voterB);
        dao.castVote(id, 1);
        vm.prank(voterC);
        dao.castVote(id, 1);

        uint256 proposerBefore = proposer.balance;
        vm.warp(block.timestamp + PERIOD + 2 days + 1);
        dao.execute(id, "Adds 0xACE as an oracle verifier");

        assertTrue(registry.isVerifier(newVerifier));
        // Bond refunded on success.
        assertEq(proposer.balance, proposerBefore + 0.05 ether);
    }

    function test_ShortWindowTakeover_NowImpossible() public {
        // The attack the review described: a 1-second window with throwaway
        // voters. It now reverts at propose().
        address[] memory sockPuppets = new address[](3);
        sockPuppets[0] = address(0x1001);
        sockPuppets[1] = address(0x1002);
        sockPuppets[2] = address(0x1003);

        vm.prank(attacker);
        vm.expectRevert(SweeftDAO2.BadVotingPeriod.selector);
        dao.propose{ value: 0.05 ether }(address(registry), _callData(), "seize", "seize", 1);
    }

    // ------------------------------------------------------------------
    // Vote hygiene
    // ------------------------------------------------------------------

    function test_CastVote_RejectsBadChoice() public {
        uint256 id = _propose(PERIOD);
        vm.prank(voterA);
        vm.expectRevert(SweeftDAO2.BadChoice.selector);
        dao.castVote(id, 9);
    }

    function test_MinVoterBalance_Enforced() public {
        dao.setMinVoterBalance(5 ether);
        uint256 id = _propose(PERIOD);

        address broke = address(0x0B0B);
        vm.deal(broke, 1 ether); // below the 5 QOR gate
        vm.prank(broke);
        vm.expectRevert(SweeftDAO2.VoterBelowMinimum.selector);
        dao.castVote(id, 1);

        // A funded voter passes the gate.
        vm.prank(voterB);
        dao.castVote(id, 1);
    }
}
