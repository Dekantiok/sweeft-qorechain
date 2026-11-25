// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SweeftDAO2 — stake-weighted proposal registry
/// @notice Governs Sweeft parameters. Executed proposals call allowlisted
///         (target, selector) pairs only.
///
///         Voting is stake-weighted (v6, N-5): a voter escrows QOR with their
///         vote and the escrowed amount is their voting power. The stake is
///         locked until the proposal reaches a final state, so a Sybil cartel
///         must lock real capital for every vote — three throwaway wallets no
///         longer pass a proposal for free. Quorum is measured in escrowed
///         stake, not wallet count.
///
///         Other hardening:
///           - a guardian may veto a passed proposal during the timelock
///             (a temporary safety valve; renounceable)
///           - self-governance selectors require a higher `criticalQuorumStake`
///           - proposals can be cancelled (by the proposer) or expired, and a
///             passed-but-reverting proposal is marked `Failed` rather than
///             left `Open` forever
///           - forfeited bonds go to a `treasury` (EOA/DAO), and failed pushes
///             become pull-payments (`pendingReturns`, `treasuryCredits`)
contract SweeftDAO2 {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum ProposalState {
        None,
        Open,
        Executed,
        Rejected,
        Cancelled,
        Expired,
        Failed,
        Vetoed
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

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, address indexed target, string title, uint64 votingEndsAt, uint64 executeAfter, bool critical);
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint8 choice);
    event VoteStakeWithdrawn(uint256 indexed proposalId, address indexed voter, uint256 amount);
    event ProposalExecuted(uint256 indexed proposalId, bytes result);
    event ProposalRejected(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event ProposalExpired(uint256 indexed proposalId);
    event ProposalFailed(uint256 indexed proposalId, bytes reason);
    event ProposalVetoed(uint256 indexed proposalId, address indexed guardian);
    event TargetUpdated(address indexed target, bool allowed);
    event CallUpdated(address indexed target, bytes4 selector, bool allowed, bool critical);
    event QuorumUpdated(uint256 previousQuorum, uint256 newQuorum);
    event CriticalQuorumUpdated(uint256 previousQuorum, uint256 newQuorum);
    event MinVoteStakeUpdated(uint256 previousStake, uint256 newStake);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ReturnWithdrawn(address indexed account, uint256 amount);
    event TreasuryCreditsWithdrawn(address indexed treasury, uint256 amount);
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
    error TargetNotAllowed();
    error CallNotAllowed();
    error NotOwner();
    error NotGuardian();
    error NotProposer();
    error NotTreasury();
    error BadVotingPeriod();
    error BadChoice();
    error WrongBond();
    error QuorumNotMet();
    error TimelockActive();
    error TimelockOver();
    error VoteStakeTooLow();
    error NoVoteStake();
    error VoteStakeLocked();
    error NothingToWithdraw();
    error TransferFailed();
    error ProposalNotExpired();

    // ------------------------------------------------------------------
    // Constants / storage
    // ------------------------------------------------------------------

    uint64 public constant MIN_VOTING_PERIOD = 3 days;
    uint64 public constant MAX_VOTING_PERIOD = 14 days;
    uint64 public constant TIMELOCK = 2 days;
    uint64 public constant PROPOSAL_TTL = 30 days;
    uint256 public constant PROPOSER_BOND = 0.05 ether;

    uint8 internal constant CHOICE_FOR = 1;
    uint8 internal constant CHOICE_AGAINST = 2;
    uint8 internal constant CHOICE_ABSTAIN = 3;

    address public owner;
    /// @notice Temporary safety valve: may veto a passed proposal during the
    ///         timelock. Renounceable via `setGuardian(address(0))`.
    address public guardian;
    /// @notice Receives forfeited proposer bonds (never left stranded).
    address public treasury;

    /// @notice Minimum QOR a voter must escrow with their vote.
    uint256 public minVoteStake = 0.01 ether;
    /// @notice Quorum, measured in escrowed voting stake (wei), for ordinary
    ///         proposals. Default: three minimum stakes.
    uint256 public quorumStake = 0.03 ether;
    /// @notice Higher quorum for self-governance selectors.
    uint256 public criticalQuorumStake = 0.05 ether;

    mapping(address => bool) public allowedTargets;
    mapping(address => mapping(bytes4 => bool)) public allowedCalls;
    mapping(address => mapping(bytes4 => bool)) public criticalCalls;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    /// @notice QOR escrowed with a vote, withdrawable once the proposal is final.
    mapping(uint256 => mapping(address => uint256)) public voteStake;

    /// @notice Pull-payment credits for a bond/treasury push that failed.
    mapping(address => uint256) public pendingReturns;
    uint256 public treasuryCredits;

    uint256 private _lock = 1;

    constructor(address[] memory initialTargets) {
        owner = msg.sender;
        guardian = msg.sender;
        treasury = msg.sender;
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
        if (_lock != 1) revert ProposalNotOpen();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        allowedTargets[target] = allowed;
        emit TargetUpdated(target, allowed);
    }

    function setAllowedCall(address target, bytes4 selector, bool allowed) external onlyOwner {
        allowedCalls[target][selector] = allowed;
        emit CallUpdated(target, selector, allowed, criticalCalls[target][selector]);
    }

    /// @notice Mark a (target, selector) as self-governance-critical, requiring
    ///         `criticalQuorumStake`.
    function setCriticalCall(address target, bytes4 selector, bool critical) external onlyOwner {
        criticalCalls[target][selector] = critical;
        emit CallUpdated(target, selector, allowedCalls[target][selector], critical);
    }

    function setQuorumStake(uint256 newQuorum) external onlyOwner {
        emit QuorumUpdated(quorumStake, newQuorum);
        quorumStake = newQuorum;
    }

    function setCriticalQuorumStake(uint256 newQuorum) external onlyOwner {
        emit CriticalQuorumUpdated(criticalQuorumStake, newQuorum);
        criticalQuorumStake = newQuorum;
    }

    function setMinVoteStake(uint256 newStake) external onlyOwner {
        emit MinVoteStakeUpdated(minVoteStake, newStake);
        minVoteStake = newStake;
    }

    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert NotOwner();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert NotOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    // ------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------

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

        emit ProposalCreated(proposalId, msg.sender, target, title, p.votingEndsAt, p.executeAfter, criticalCalls[target][bytes4(callData)]);
    }

    /// @notice Vote with escrowed QOR. Voting power is the escrowed amount.
    ///         The stake is locked until the proposal reaches a final state.
    function castVote(uint256 proposalId, uint8 choice) external payable {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp >= p.votingEndsAt) revert VotingClosed();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();
        if (choice != CHOICE_FOR && choice != CHOICE_AGAINST && choice != CHOICE_ABSTAIN) revert BadChoice();
        if (msg.value < minVoteStake) revert VoteStakeTooLow();

        hasVoted[proposalId][msg.sender] = true;
        voteStake[proposalId][msg.sender] += msg.value;

        if (choice == CHOICE_FOR) {
            p.forVotes += msg.value;
        } else if (choice == CHOICE_AGAINST) {
            p.againstVotes += msg.value;
        } else {
            p.abstainVotes += msg.value;
        }

        emit VoteCast(proposalId, msg.sender, choice);
    }

    /// @notice Reclaim the QOR escrowed with a vote once the proposal is final.
    function withdrawVoteStake(uint256 proposalId) external nonReentrant {
        uint256 amount = voteStake[proposalId][msg.sender];
        if (amount == 0) revert NoVoteStake();
        ProposalState state = proposals[proposalId].state;
        if (state == ProposalState.None || state == ProposalState.Open) revert VoteStakeLocked();

        voteStake[proposalId][msg.sender] = 0;
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit VoteStakeWithdrawn(proposalId, msg.sender, amount);
    }

    /// @notice Execute a passed proposal after the timelock, or finalize it.
    function execute(uint256 proposalId, string calldata description) external nonReentrant returns (bytes memory result) {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp < p.executeAfter) revert TimelockActive();
        if (keccak256(bytes(description)) != p.descriptionHash) revert DescriptionMismatch();

        uint256 requiredQuorum = criticalCalls[p.target][bytes4(p.callData)] ? criticalQuorumStake : quorumStake;
        bool passed = p.forVotes > p.againstVotes && (p.forVotes + p.againstVotes) >= requiredQuorum;

        if (!passed) {
            p.state = ProposalState.Rejected;
            _payTreasury(PROPOSER_BOND);
            emit ProposalRejected(proposalId);
            return "";
        }

        bool ok;
        (ok, result) = p.target.call(p.callData);
        if (!ok) {
            // Mark Failed rather than reverting, so it cannot stay Open forever.
            p.state = ProposalState.Failed;
            _payTreasury(PROPOSER_BOND);
            emit ProposalFailed(proposalId, result);
            return result;
        }

        p.state = ProposalState.Executed;
        _refundBond(p.proposer);
        emit ProposalExecuted(proposalId, result);
    }

    /// @notice Guardian veto during the timelock (temporary safety valve).
    function veto(uint256 proposalId) external nonReentrant {
        if (msg.sender != guardian) revert NotGuardian();
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp >= p.executeAfter) revert TimelockOver();

        p.state = ProposalState.Vetoed;
        _payTreasury(PROPOSER_BOND);
        emit ProposalVetoed(proposalId, msg.sender);
    }

    /// @notice Proposer may cancel their own proposal before voting closes.
    function cancel(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (msg.sender != p.proposer && msg.sender != owner) revert NotProposer();
        if (block.timestamp >= p.votingEndsAt) revert VotingClosed();

        p.state = ProposalState.Cancelled;
        _refundBond(p.proposer);
        emit ProposalCancelled(proposalId);
    }

    /// @notice Permissionless expiry of a stale, never-executed proposal.
    function expireProposal(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp < uint256(p.executeAfter) + PROPOSAL_TTL) revert ProposalNotExpired();

        p.state = ProposalState.Expired;
        _payTreasury(PROPOSER_BOND);
        emit ProposalExpired(proposalId);
    }

    // ------------------------------------------------------------------
    // Pull payments (failed pushes never strand funds)
    // ------------------------------------------------------------------

    function withdrawReturn() external nonReentrant {
        uint256 amount = pendingReturns[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingReturns[msg.sender] = 0;
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit ReturnWithdrawn(msg.sender, amount);
    }

    function withdrawTreasuryCredits() external nonReentrant {
        if (msg.sender != treasury) revert NotTreasury();
        uint256 amount = treasuryCredits;
        if (amount == 0) revert NothingToWithdraw();
        treasuryCredits = 0;
        (bool ok,) = treasury.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit TreasuryCreditsWithdrawn(treasury, amount);
    }

    // ------------------------------------------------------------------
    // Internal transfers
    // ------------------------------------------------------------------

    function _refundBond(address to) internal {
        if (to == address(0)) return;
        (bool ok,) = to.call{ value: PROPOSER_BOND }("");
        if (!ok) pendingReturns[to] += PROPOSER_BOND;
    }

    function _payTreasury(uint256 amount) internal {
        if (amount == 0 || treasury == address(0)) return;
        (bool ok,) = treasury.call{ value: amount }("");
        if (!ok) treasuryCredits += amount;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function isExecutable(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        return p.state == ProposalState.Open && block.timestamp >= p.executeAfter;
    }
}
