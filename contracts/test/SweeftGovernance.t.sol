// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SweeftOracleRegistry } from "../src/SweeftOracleRegistry.sol";
import { SweeftDAO } from "../src/SweeftDAO.sol";

contract SweeftOracleRegistryTest is Test {
    SweeftOracleRegistry internal registry;

    address internal owner = address(this);
    address internal verifier = address(0xACE);
    address internal stranger = address(0xCAFE);

    function setUp() public {
        registry = new SweeftOracleRegistry(owner);
    }

    function test_AddVerifier_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(SweeftOracleRegistry.NotOwner.selector);
        registry.addVerifier(verifier);

        registry.addVerifier(verifier);
        assertTrue(registry.isVerifier(verifier));
    }

    function test_AddVerifier_RejectsDuplicate() public {
        registry.addVerifier(verifier);
        vm.expectRevert(SweeftOracleRegistry.AlreadyVerifier.selector);
        registry.addVerifier(verifier);
    }

    function test_AddVerifier_RejectsZeroAddress() public {
        vm.expectRevert(SweeftOracleRegistry.ZeroAddress.selector);
        registry.addVerifier(address(0));
    }

    function test_RemoveVerifier() public {
        registry.addVerifier(verifier);

        vm.prank(stranger);
        vm.expectRevert(SweeftOracleRegistry.NotOwner.selector);
        registry.removeVerifier(verifier);

        registry.removeVerifier(verifier);
        assertFalse(registry.isVerifier(verifier));
    }

    function test_RemoveVerifier_RejectsUnknown() public {
        vm.expectRevert(SweeftOracleRegistry.NotVerifier.selector);
        registry.removeVerifier(verifier);
    }

    function test_TransferOwnership() public {
        registry.transferOwnership(stranger);
        assertEq(registry.owner(), stranger);

        // Old owner loses power.
        vm.expectRevert(SweeftOracleRegistry.NotOwner.selector);
        registry.addVerifier(verifier);
    }
}

contract SweeftDAOTest is Test {
    SweeftOracleRegistry internal registry;
    SweeftDAO internal dao;

    address internal proposer = address(0xF00D);
    address internal voterA = address(0xA1);
    address internal voterB = address(0xB2);
    address internal newVerifier = address(0xACE);

    uint64 internal constant VOTING_PERIOD = 1 days;

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        dao = new SweeftDAO(address(registry));
        // The DAO must own the registry for executed proposals to take effect.
        registry.transferOwnership(address(dao));
    }

    function _verifierProposalCallData() internal view returns (bytes memory) {
        return abi.encodeWithSignature("addVerifier(address)", newVerifier);
    }

    function _createProposal() internal returns (uint256) {
        vm.prank(proposer);
        return dao.propose(_verifierProposalCallData(), "Approve verifier 0xACE", "Adds 0xACE as an oracle verifier", VOTING_PERIOD);
    }

    // ------------------------------------------------------------------
    // Proposal lifecycle
    // ------------------------------------------------------------------

    function test_FullFlow_ApproveVerifier() public {
        uint256 id = _createProposal();

        vm.prank(voterA);
        dao.castVote(id, 1); // for
        vm.prank(voterB);
        dao.castVote(id, 1); // for

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertTrue(dao.isExecutable(id));

        dao.execute(id, "Adds 0xACE as an oracle verifier");

        assertTrue(registry.isVerifier(newVerifier));
        assertEq(uint8(dao.getProposal(id).state), uint8(SweeftDAO.ProposalState.Executed));
    }

    function test_ProposalRejected_WhenVotesFail() public {
        uint256 id = _createProposal();

        vm.prank(voterA);
        dao.castVote(id, 2); // against

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        dao.execute(id, "Adds 0xACE as an oracle verifier");

        assertFalse(registry.isVerifier(newVerifier));
        assertEq(uint8(dao.getProposal(id).state), uint8(SweeftDAO.ProposalState.Rejected));
    }

    function test_OneVotePerWallet() public {
        uint256 id = _createProposal();

        vm.prank(voterA);
        dao.castVote(id, 1);

        vm.prank(voterA);
        vm.expectRevert(SweeftDAO.AlreadyVoted.selector);
        dao.castVote(id, 1);
    }

    function test_CannotVoteAfterDeadline() public {
        uint256 id = _createProposal();
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.prank(voterA);
        vm.expectRevert(SweeftDAO.VotingClosed.selector);
        dao.castVote(id, 1);
    }

    function test_CannotExecuteWhileVotingOpen() public {
        uint256 id = _createProposal();

        vm.expectRevert(SweeftDAO.VotingStillOpen.selector);
        dao.execute(id, "Adds 0xACE as an oracle verifier");
    }

    function test_DescriptionMustMatch() public {
        uint256 id = _createProposal();
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.expectRevert(SweeftDAO.DescriptionMismatch.selector);
        dao.execute(id, "TAMPERED description");
    }

    function test_CannotExecuteTwice() public {
        uint256 id = _createProposal();

        vm.prank(voterA);
        dao.castVote(id, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        dao.execute(id, "Adds 0xACE as an oracle verifier");

        vm.expectRevert(SweeftDAO.ProposalNotOpen.selector);
        dao.execute(id, "Adds 0xACE as an oracle verifier");
    }

    function test_AbstainDoesNotCount() public {
        uint256 id = _createProposal();

        vm.prank(voterA);
        dao.castVote(id, 3); // abstain

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        dao.execute(id, "Adds 0xACE as an oracle verifier");

        // No for-votes, no against-votes: proposal is rejected (for <= against).
        assertFalse(registry.isVerifier(newVerifier));
    }
}
