// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SweeftDAO2 — proposal registry and one-wallet-one-vote governance
/// @notice Governs Sweeft application parameters. Executed proposals call
///         allowlisted contracts only: the oracle registry (verifier
///         approval), the vault (fee and treasury settings), and the dispute
///         board (stake and voting parameters).
contract SweeftDAO2 {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum ProposalState {
        None,
        Open,
        Executed,
        Rejected
    }

    struct Proposal {
        address proposer;
        address target;
        bytes callData;
        bytes32 descriptionHash;
        string title;
        uint64 createdAt;
        uint64 votingEndsAt;
        uint256 forVotes;
        uint256 againstVotes;
        ProposalState state;
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, address indexed target, string title, uint64 votingEndsAt);
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint8 choice); // 1=for 2=against 3=abstain
    event ProposalExecuted(uint256 indexed proposalId, bytes result);
    event ProposalRejected(uint256 indexed proposalId);
    event TargetUpdated(address indexed target, bool allowed);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error EmptyTitle();
    error DescriptionMismatch();
    error VotingClosed();
    error VotingStillOpen();
    error AlreadyVoted();
    error ProposalNotOpen();
    error ProposalFailed();
    error TargetNotAllowed();
    error NotOwner();

    // ------------------------------------------------------------------
    // Constants / storage
    // ------------------------------------------------------------------

    uint256 internal constant MAX_VOTES = 10_000;
    uint8 internal constant CHOICE_FOR = 1;
    uint8 internal constant CHOICE_AGAINST = 2;
    uint8 internal constant CHOICE_ABSTAIN = 3;

    address public owner;
    mapping(address => bool) public allowedTargets;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    constructor(address[] memory initialTargets) {
        owner = msg.sender;
        for (uint256 i = 0; i < initialTargets.length; i++) {
            allowedTargets[initialTargets[i]] = true;
            emit TargetUpdated(initialTargets[i], true);
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Update the call allowlist (owner; for migration only).
    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        allowedTargets[target] = allowed;
        emit TargetUpdated(target, allowed);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    // ------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------

    /// @notice Create a proposal that, if passed, executes `callData` against
    ///         an allowlisted target.
    function propose(address target, bytes calldata callData, string calldata title, string calldata description, uint64 votingPeriod)
        external
        returns (uint256 proposalId)
    {
        if (bytes(title).length == 0) revert EmptyTitle();
        if (!allowedTargets[target]) revert TargetNotAllowed();

        proposalId = proposalCount;
        proposalCount = proposalId + 1;

        Proposal storage p = proposals[proposalId];
        p.proposer = msg.sender;
        p.target = target;
        p.callData = callData;
        p.descriptionHash = keccak256(bytes(description));
        p.title = title;
        p.createdAt = uint64(block.timestamp);
        p.votingEndsAt = uint64(block.timestamp) + votingPeriod;
        p.state = ProposalState.Open;

        emit ProposalCreated(proposalId, msg.sender, target, title, p.votingEndsAt);
    }

    /// @notice One vote per wallet per proposal.
    function castVote(uint256 proposalId, uint8 choice) external {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp >= p.votingEndsAt) revert VotingClosed();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();

        hasVoted[proposalId][msg.sender] = true;

        if (choice == CHOICE_FOR) {
            if (p.forVotes >= MAX_VOTES) revert ProposalFailed();
            p.forVotes += 1;
        } else if (choice == CHOICE_AGAINST) {
            if (p.againstVotes >= MAX_VOTES) revert ProposalFailed();
            p.againstVotes += 1;
        }

        emit VoteCast(proposalId, msg.sender, choice);
    }

    /// @notice Execute a passed proposal against its target, or finalize it as
    ///         rejected when the votes do not pass.
    function execute(uint256 proposalId, string calldata description) external returns (bytes memory result) {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp < p.votingEndsAt) revert VotingStillOpen();
        if (keccak256(bytes(description)) != p.descriptionHash) revert DescriptionMismatch();

        if (p.forVotes <= p.againstVotes) {
            p.state = ProposalState.Rejected;
            emit ProposalRejected(proposalId);
            return "";
        }

        p.state = ProposalState.Executed;

        bool ok;
        (ok, result) = p.target.call(p.callData);
        if (!ok) {
            // Bubble the target's revert reason instead of masking it.
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert ProposalFailed();
        }

        emit ProposalExecuted(proposalId, result);
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function isExecutable(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        return p.state == ProposalState.Open && block.timestamp >= p.votingEndsAt;
    }
}
