// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SweeftDAO2 — proposal registry and one-wallet-one-vote governance
/// @notice Governs Sweeft application parameters. Executed proposals call
///         allowlisted (target, selector) pairs only: the oracle registry
///         (verifier approval, threshold), the vault (fee, treasury) and the
///         dispute board (stake, voting parameters).
///
///         Hardening (v5):
///           - voting periods are bounded (MIN_VOTING_PERIOD..MAX_VOTING_PERIOD)
///           - a quorum and a simple majority are both required to execute
///           - a timelock separates "passed" from "executable" so holders can
///             react (and an executor can be front-run only after the delay)
///           - only (target, selector) pairs on an allowlist may be called, so
///             a proposal cannot smuggle an arbitrary call into a privileged
///             contract
///           - proposers post a bond, returned when their proposal passes and
///             forfeited (to the DAO owner) when it is rejected or misses quorum
///           - votes must be 1 (for) / 2 (against) / 3 (abstain)
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
        uint64 executeAfter;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        ProposalState state;
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, address indexed target, string title, uint64 votingEndsAt, uint64 executeAfter);
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint8 choice); // 1=for 2=against 3=abstain
    event ProposalExecuted(uint256 indexed proposalId, bytes result);
    event ProposalRejected(uint256 indexed proposalId);
    event TargetUpdated(address indexed target, bool allowed);
    event CallUpdated(address indexed target, bytes4 selector, bool allowed);
    event QuorumUpdated(uint256 previousQuorum, uint256 newQuorum);
    event MinVoterBalanceUpdated(uint256 previousBalance, uint256 newBalance);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

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
    error CallNotAllowed();
    error NotOwner();
    error BadVotingPeriod();
    error BadChoice();
    error WrongBond();
    error QuorumNotMet();
    error TimelockActive();
    error VoterBelowMinimum();
    error TransferFailed();

    // ------------------------------------------------------------------
    // Constants / storage
    // ------------------------------------------------------------------

    uint64 public constant MIN_VOTING_PERIOD = 3 days;
    uint64 public constant MAX_VOTING_PERIOD = 14 days;
    uint64 public constant TIMELOCK = 2 days;
    uint256 public constant PROPOSER_BOND = 0.05 ether;

    uint8 internal constant CHOICE_FOR = 1;
    uint8 internal constant CHOICE_AGAINST = 2;
    uint8 internal constant CHOICE_ABSTAIN = 3;

    address public owner;
    /// @notice Minimum decisive votes (for + against) required to execute.
    uint256 public quorum = 3;
    /// @notice Native QOR balance a voter must hold to cast a vote (0 = open).
    ///         A cheap Sybil cost; combine with reputation/stake off-chain.
    uint256 public minVoterBalance = 0;

    mapping(address => bool) public allowedTargets;
    mapping(address => mapping(bytes4 => bool)) public allowedCalls;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    uint256 private _lock = 1;

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

    modifier nonReentrant() {
        if (_lock != 1) revert ProposalFailed();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ------------------------------------------------------------------
    // Configuration (owner; transfer ownership to the DAO after wiring)
    // ------------------------------------------------------------------

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        allowedTargets[target] = allowed;
        emit TargetUpdated(target, allowed);
    }

    /// @notice Allow or deny a specific (target, selector) pair.
    function setAllowedCall(address target, bytes4 selector, bool allowed) external onlyOwner {
        allowedCalls[target][selector] = allowed;
        emit CallUpdated(target, selector, allowed);
    }

    function setQuorum(uint256 newQuorum) external onlyOwner {
        emit QuorumUpdated(quorum, newQuorum);
        quorum = newQuorum;
    }

    function setMinVoterBalance(uint256 newBalance) external onlyOwner {
        emit MinVoterBalanceUpdated(minVoterBalance, newBalance);
        minVoterBalance = newBalance;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert NotOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Renounce ownership so no EOA can alter the allowlist.
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    // ------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------

    /// @notice Create a proposal that, if it passes and the timelock elapses,
    ///         executes `callData` against an allowlisted (target, selector).
    function propose(address target, bytes calldata callData, string calldata title, string calldata description, uint64 votingPeriod)
        external
        payable
        returns (uint256 proposalId)
    {
        if (bytes(title).length == 0) revert EmptyTitle();
        if (msg.value != PROPOSER_BOND) revert WrongBond();
        if (!allowedTargets[target]) revert TargetNotAllowed();
        if (callData.length < 4) revert CallNotAllowed();
        if (!allowedCalls[target][bytes4(callData)]) revert CallNotAllowed();
        if (votingPeriod < MIN_VOTING_PERIOD || votingPeriod > MAX_VOTING_PERIOD) revert BadVotingPeriod();

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
        p.executeAfter = p.votingEndsAt + TIMELOCK;
        p.state = ProposalState.Open;

        emit ProposalCreated(proposalId, msg.sender, target, title, p.votingEndsAt, p.executeAfter);
    }

    /// @notice One vote per wallet per proposal.
    function castVote(uint256 proposalId, uint8 choice) external {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp >= p.votingEndsAt) revert VotingClosed();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();
        if (choice != CHOICE_FOR && choice != CHOICE_AGAINST && choice != CHOICE_ABSTAIN) revert BadChoice();
        if (minVoterBalance > 0 && msg.sender.balance < minVoterBalance) revert VoterBelowMinimum();

        hasVoted[proposalId][msg.sender] = true;

        if (choice == CHOICE_FOR) {
            p.forVotes += 1;
        } else if (choice == CHOICE_AGAINST) {
            p.againstVotes += 1;
        } else {
            p.abstainVotes += 1;
        }

        emit VoteCast(proposalId, msg.sender, choice);
    }

    /// @notice Execute a passed proposal after the timelock, or finalize it as
    ///         rejected. Returns the proposer's bond on success.
    function execute(uint256 proposalId, string calldata description) external nonReentrant returns (bytes memory result) {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp < p.executeAfter) revert TimelockActive();
        if (keccak256(bytes(description)) != p.descriptionHash) revert DescriptionMismatch();

        bool passed = p.forVotes > p.againstVotes && (p.forVotes + p.againstVotes) >= quorum;

        if (!passed) {
            p.state = ProposalState.Rejected;
            _send(owner, PROPOSER_BOND); // forfeit to the DAO owner (or burn if renounced)
            emit ProposalRejected(proposalId);
            return "";
        }

        p.state = ProposalState.Executed;

        bool ok;
        (ok, result) = p.target.call(p.callData);
        if (!ok) {
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert ProposalFailed();
        }

        _send(p.proposer, PROPOSER_BOND);
        emit ProposalExecuted(proposalId, result);
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0 || to == address(0)) return; // renounced: bond stays in the DAO
        // A recipient that rejects the transfer simply leaves the bond in the
        // DAO; execution must never fail because of a bond payout.
        (bool ok,) = to.call{ value: amount }("");
        ok; // silence unused warning
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function isExecutable(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        return p.state == ProposalState.Open && block.timestamp >= p.executeAfter;
    }
}
