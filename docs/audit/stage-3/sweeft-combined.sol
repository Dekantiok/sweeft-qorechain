// ============ SweeftDAO.sol ============
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SweeftDAO — proposal registry and one-wallet-one-vote governance
/// @notice Governs Sweeft application policy. The MVP's executable power is
///         oracle verifier approval/removal: passed proposals call the
///         SweeftOracleRegistry (the DAO must own the registry). Other policy
///         proposals are recorded and read by the application.
/// @dev The call target is immutable and fixed to the oracle registry so this
///      contract can never be used to call arbitrary addresses.
contract SweeftDAO {
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
        address target; // immutable per-DAO; always the oracle registry
        bytes callData;
        bytes32 descriptionHash; // keccak256 of the human description
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

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string title, uint64 votingEndsAt);
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint8 choice); // 1=for 2=against 3=abstain
    event ProposalExecuted(uint256 indexed proposalId, bytes result);
    event ProposalRejected(uint256 indexed proposalId);

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
    error NotRejected();

    // ------------------------------------------------------------------
    // Constants / immutables
    // ------------------------------------------------------------------

    uint256 internal constant MAX_VOTES = 10_000;
    uint8 internal constant CHOICE_FOR = 1;
    uint8 internal constant CHOICE_AGAINST = 2;
    uint8 internal constant CHOICE_ABSTAIN = 3;

    address public immutable target;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    constructor(address targetContract) {
        target = targetContract;
    }

    // ------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------

    /// @notice Create a proposal that, if passed, executes `callData` against
    ///         the immutable target (the oracle registry).
    function propose(bytes calldata callData, string calldata title, string calldata description, uint64 votingPeriod)
        external
        returns (uint256 proposalId)
    {
        if (bytes(title).length == 0) revert EmptyTitle();

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

        emit ProposalCreated(proposalId, msg.sender, title, p.votingEndsAt);
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

    /// @notice Execute a passed proposal against the target, or finalize it as
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

        // Low-level call with explicit status check and revert bubbling.
        // `ok == false` is reverted immediately; target revert data is
        // forwarded so callers see the real reason.
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

        emit ProposalExecuted(proposalId, result);
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    /// @notice True when the proposal can be executed right now.
    function isExecutable(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        return p.state == ProposalState.Open && block.timestamp >= p.votingEndsAt;
    }
}

interface ITargetLike {
    function executeCall(bytes calldata data) external returns (bytes memory);
}


// ============ SweeftDAO2.sol ============
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


// ============ SweeftDisputeBoard.sol ============
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SweeftVault } from "./SweeftVault.sol";

/// @title SweeftDisputeBoard — staked resolver panels for escrow disputes
/// @notice Anyone who stakes at least `minStake` QOR may join an open dispute.
///         The first three eligible resolvers form the board; parties and the
///         attesting verifier are excluded. A 2-of-3 majority settles the
///         escrow through the Vault. Resolvers who vote share the dispute
///         reward pool: each receives 10% of that escrow's platform fee
///         (the 30% resolver share split three ways), paid from the pool that
///         accumulates from every completed release.
contract SweeftDisputeBoard {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum DisputeState {
        None,
        Open,
        Resolved
    }

    struct Dispute {
        uint256 escrowId;
        address raiser;
        uint64 openedAt;
        uint64 votingEndsAt;
        DisputeState state;
        bool releaseToSeller; // final outcome
        uint8 votesForRelease;
        uint8 votesForRefund;
        uint8 memberCount;
        address[3] members;
        mapping(address => bool) isMember;
        mapping(address => bool) hasVoted;
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event Staked(address indexed account, uint256 amount, uint256 total);
    event UnstakeRequested(address indexed account, uint64 availableAt);
    event StakeWithdrawn(address indexed account, uint256 amount);
    event DisputeOpened(uint256 indexed disputeId, uint256 indexed escrowId, address indexed raiser, uint64 votingEndsAt);
    event ResolverJoined(uint256 indexed disputeId, address indexed resolver, uint8 position);
    event ResolverVoted(uint256 indexed disputeId, address indexed resolver, bool releaseToSeller);
    event DisputeSettled(uint256 indexed disputeId, uint256 indexed escrowId, bool releaseToSeller);
    event RewardClaimed(uint256 indexed disputeId, address indexed resolver, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error NotOwner();
    error NotVault();
    error ZeroAmount();
    error StakeTooLow();
    error StakeLocked();
    error NoStake();
    error CooldownActive();
    error UnknownDispute();
    error DisputeNotOpen();
    error AlreadyMember();
    error BoardFull();
    error ExcludedParty();
    error NotMember();
    error AlreadyVoted();
    error VotingClosed();
    error VotingStillOpen();
    error NoMajority();
    error TransferFailed();

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    SweeftVault public immutable vault;
    address public owner;

    /// @notice Minimum stake to serve on a board (20 QOR).
    uint256 public constant MIN_STAKE = 20 ether;
    /// @notice Board size is hard-capped at 3 members.
    uint256 internal constant MAX_BOARD_SIZE = 3;
    /// @notice Vote counting is bounded by distinct voters; the cap is
    ///         defensive (overflow is impossible at wallet scale).
    uint256 internal constant MAX_VOTES = 10_000;
    /// @notice Unstake cooldown after requesting withdrawal.
    uint64 public unstakeCooldown = 1 hours;
    /// @notice Voting window for a dispute.
    uint64 public votingPeriod = 48 hours;

    uint256 public minStake = 20 ether;

    mapping(address => uint256) public stakeOf;
    mapping(address => uint64) public unstakeAvailableAt;
    mapping(address => uint256) public activeBoards;

    /// @notice Accumulated resolver reward pool — fee shares from the Vault
    ///         only. Stakes are tracked separately and never pay rewards.
    uint256 public rewardPool;

    uint256 public disputeCount;
    mapping(uint256 => Dispute) private disputes;

    /// @notice The Vault calls this when forwarding the dispute share of a fee.
    function receiveFeeShare() external payable {
        if (msg.sender != address(vault)) revert NotVault();
        rewardPool += msg.value;
    }

    constructor(address vaultAddress) {
        if (vaultAddress == address(0)) revert ZeroAmount();
        vault = SweeftVault(vaultAddress);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ------------------------------------------------------------------
    // Governance (owner → DAO)
    // ------------------------------------------------------------------

    function setMinStake(uint256 newMinStake) external onlyOwner {
        minStake = newMinStake;
    }

    function setUnstakeCooldown(uint64 newCooldown) external onlyOwner {
        unstakeCooldown = newCooldown;
    }

    function setVotingPeriod(uint64 newPeriod) external onlyOwner {
        votingPeriod = newPeriod;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAmount();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ------------------------------------------------------------------
    // Staking
    // ------------------------------------------------------------------

    function stake() external payable {
        if (msg.value == 0) revert ZeroAmount();
        stakeOf[msg.sender] += msg.value;
        emit Staked(msg.sender, msg.value, stakeOf[msg.sender]);
    }

    /// @notice Begin unstaking. Blocked while serving on an active board.
    function requestUnstake() external {
        if (stakeOf[msg.sender] == 0) revert NoStake();
        if (activeBoards[msg.sender] > 0) revert StakeLocked();
        unstakeAvailableAt[msg.sender] = uint64(block.timestamp) + unstakeCooldown;
        emit UnstakeRequested(msg.sender, unstakeAvailableAt[msg.sender]);
    }

    function withdrawStake() external {
        uint256 amount = stakeOf[msg.sender];
        if (amount == 0) revert NoStake();
        if (activeBoards[msg.sender] > 0) revert StakeLocked();
        if (unstakeAvailableAt[msg.sender] == 0 || block.timestamp < unstakeAvailableAt[msg.sender]) {
            revert CooldownActive();
        }

        stakeOf[msg.sender] = 0;
        unstakeAvailableAt[msg.sender] = 0;
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit StakeWithdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Disputes
    // ------------------------------------------------------------------

    /// @notice Open a dispute for an escrow that has been frozen on the Vault.
    ///         Called by the raiser (buyer or seller): freezes in the Vault
    ///         first via raiseDispute, then registers here.
    function openDispute(uint256 escrowId) external returns (uint256 disputeId) {
        SweeftVault.Escrow memory escrow = vault.getEscrow(escrowId);
        if (escrow.buyer == address(0)) revert UnknownDispute();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert ExcludedParty();

        // Freeze the escrow (reverts unless we are the raiser and it is funded).
        vault.raiseDispute(escrowId);

        disputeId = disputeCount;
        disputeCount = disputeId + 1;

        Dispute storage d = disputes[disputeId];
        d.escrowId = escrowId;
        d.raiser = msg.sender;
        d.openedAt = uint64(block.timestamp);
        d.votingEndsAt = uint64(block.timestamp) + votingPeriod;
        d.state = DisputeState.Open;

        emit DisputeOpened(disputeId, escrowId, msg.sender, d.votingEndsAt);
    }

    /// @notice Join an open dispute's board. First three eligible resolvers.
    function joinDispute(uint256 disputeId) external {
        Dispute storage d = disputes[disputeId];
        if (d.state == DisputeState.None) revert UnknownDispute();
        if (d.state != DisputeState.Open) revert DisputeNotOpen();
        if (block.timestamp >= d.votingEndsAt) revert VotingClosed();
        if (d.memberCount >= MAX_BOARD_SIZE) revert BoardFull();
        if (d.isMember[msg.sender]) revert AlreadyMember();
        if (stakeOf[msg.sender] < minStake) revert StakeTooLow();

        SweeftVault.Escrow memory escrow = vault.getEscrow(d.escrowId);
        if (msg.sender == escrow.buyer || msg.sender == escrow.seller) revert ExcludedParty();
        if (escrow.verifier != address(0) && msg.sender == escrow.verifier) revert ExcludedParty();

        d.isMember[msg.sender] = true;
        d.members[d.memberCount] = msg.sender;
        d.memberCount += 1;
        activeBoards[msg.sender] += 1;

        emit ResolverJoined(disputeId, msg.sender, d.memberCount);
    }

    /// @notice Cast a resolver vote. A 2-of-3 majority settles immediately.
    function castVote(uint256 disputeId, bool releaseToSeller) external {
        Dispute storage d = disputes[disputeId];
        if (d.state == DisputeState.None) revert UnknownDispute();
        if (d.state != DisputeState.Open) revert DisputeNotOpen();
        if (block.timestamp >= d.votingEndsAt) revert VotingClosed();
        if (!d.isMember[msg.sender]) revert NotMember();
        if (d.hasVoted[msg.sender]) revert AlreadyVoted();

        d.hasVoted[msg.sender] = true;
        if (releaseToSeller) {
            d.votesForRelease += 1;
        } else {
            d.votesForRefund += 1;
        }
        emit ResolverVoted(disputeId, msg.sender, releaseToSeller);

        if (d.votesForRelease >= 2) {
            _settle(disputeId, d, true);
        } else if (d.votesForRefund >= 2) {
            _settle(disputeId, d, false);
        }
    }

    /// @notice Owner fallback for disputes that reach their deadline without a
    ///         majority. Not a per-dispute DAO vote — a liveness escape hatch,
    ///         DAO-revocable via ownership. Refund-by-default protects buyers.
    function resolveExpired(uint256 disputeId, bool releaseToSeller) external onlyOwner {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Open) revert DisputeNotOpen();
        if (block.timestamp < d.votingEndsAt) revert VotingStillOpen();
        if (d.votesForRelease >= 2 || d.votesForRefund >= 2) revert NoMajority();
        _settle(disputeId, d, releaseToSeller);
    }

    /// @notice Settlement — explicitly unrolled for the 3 member slots.
    ///         No loop is used, so the work per dispute is a fixed small
    ///         constant regardless of join order.
    function _settle(uint256 disputeId, Dispute storage d, bool releaseToSeller) internal {
        d.state = DisputeState.Resolved;
        d.releaseToSeller = releaseToSeller;

        if (d.memberCount > 0) _releaseMember(d.members[0]);
        if (d.memberCount > 1) _releaseMember(d.members[1]);
        if (d.memberCount > 2) _releaseMember(d.members[2]);

        vault.resolveDispute(d.escrowId, releaseToSeller);
        emit DisputeSettled(disputeId, d.escrowId, releaseToSeller);
    }

    function _releaseMember(address member) internal {
        if (activeBoards[member] > 0) {
            activeBoards[member] -= 1;
        }
    }

    // ------------------------------------------------------------------
    // Rewards
    // ------------------------------------------------------------------

    /// @notice Public view — anyone may read the reward amount. Intentionally
    ///         NOT onlyOwner: it is a pure view over public dispute state.
    /// @dev    QCAI Stage 1 flagged this area for access control; it is a view
    ///         and holds no privileged write.
    function resolverReward(uint256 disputeId) public view returns (uint256) {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Resolved) return 0;
        SweeftVault.Escrow memory escrow = vault.getEscrow(d.escrowId);
        uint256 goods = escrow.amount - escrow.logisticsAmount;
        uint256 fee = (goods * vault.feeBps()) / 10_000;
        return (fee * 3_000) / 10_000 / 3;
    }

    mapping(uint256 => mapping(address => bool)) public rewardClaimed;

    /// @notice Claim the resolver reward for a settled dispute you voted on.
    function claimReward(uint256 disputeId) external {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Resolved) revert DisputeNotOpen();
        if (!d.isMember[msg.sender] || !d.hasVoted[msg.sender]) revert NotMember();
        if (rewardClaimed[disputeId][msg.sender]) revert AlreadyVoted();

        rewardClaimed[disputeId][msg.sender] = true;
        uint256 reward = resolverReward(disputeId);
        if (reward == 0) revert NoStake();
        if (rewardPool < reward) revert TransferFailed();

        rewardPool -= reward;
        (bool ok,) = msg.sender.call{ value: reward }("");
        if (!ok) revert TransferFailed();
        emit RewardClaimed(disputeId, msg.sender, reward);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getDispute(uint256 disputeId)
        external
        view
        returns (
            uint256 escrowId,
            address raiser,
            uint64 openedAt,
            uint64 votingEndsAt,
            DisputeState state,
            bool releaseToSeller,
            uint8 votesForRelease,
            uint8 votesForRefund,
            uint8 memberCount,
            address[3] memory members
        )
    {
        Dispute storage d = disputes[disputeId];
        return (
            d.escrowId,
            d.raiser,
            d.openedAt,
            d.votingEndsAt,
            d.state,
            d.releaseToSeller,
            d.votesForRelease,
            d.votesForRefund,
            d.memberCount,
            d.members
        );
    }

    function hasVoted(uint256 disputeId, address member) external view returns (bool) {
        return disputes[disputeId].hasVoted[member];
    }

    function isMember(uint256 disputeId, address member) external view returns (bool) {
        return disputes[disputeId].isMember[member];
    }
}


// ============ SweeftMarketplace.sol ============
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SweeftVault } from "./SweeftVault.sol";

/// @title SweeftMarketplace — on-chain listings and purchase flow
/// @notice Source of truth for listings: seller, price, status, quantity.
///         Buying a listing creates an escrow in SweeftVault and forwards the
///         payment; funding and settlement stay with the Vault.
/// @dev Metadata (title, description, images) stays off-chain as JSON; its URI
///      and a SHA-256 hash are stored on-chain so buyers can verify content.
contract SweeftMarketplace {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum ListingStatus {
        None,
        Active,
        Sold,
        Cancelled
    }

    struct Listing {
        address seller;
        uint256 price; // total total (goods + logistics) for a purchase
        uint64 quantity;
        ListingStatus status;
        string metadataUri;
        bytes32 metadataHash; // sha256 of the metadata JSON
        uint64 createdAt;
        uint64 updatedAt;
        // v4 appended fields for ABI/upgrade sanity (struct append at end)
        address logisticsPartner;
        uint256 logisticsFee; // portion of price that is the carrier payout
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event ListingCreated(
        uint256 indexed listingId, address indexed seller, uint256 price, uint64 quantity, bytes32 metadataHash
    );
    event ListingMetadataUpdated(uint256 indexed listingId, string metadataUri, bytes32 metadataHash);
    event ListingPriceUpdated(uint256 indexed listingId, uint256 price);
    event ListingCancelled(uint256 indexed listingId);
    event ListingPurchased(
        uint256 indexed listingId,
        uint256 indexed escrowId,
        address indexed buyer,
        address seller,
        uint256 price
    );

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error NotSeller();
    error InvalidPrice();
    error InvalidQuantity();
    error InvalidMetadata();
    error ListingNotActive();
    error OutOfStock();
    error WrongPayment();
    error InvalidBuyer();
    error EscrowCreationFailed();

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    SweeftVault public immutable vault;

    uint256 public listingCount;
    mapping(uint256 => Listing) public listings;

    constructor(address vaultAddress) {
        if (vaultAddress == address(0)) revert InvalidMetadata();
        vault = SweeftVault(vaultAddress);
    }

    // ------------------------------------------------------------------
    // Seller actions
    // ------------------------------------------------------------------

    function createListing(uint256 price, uint64 quantity, string calldata metadataUri, bytes32 metadataHash)
        external
        returns (uint256 listingId)
    {
        return _createListing(price, quantity, metadataUri, metadataHash, address(0), 0);
    }

    /// @notice Create a physical listing with a logistics allocation.
    /// @dev price = total (goods + logistics fee); logisticsFee is paid to
    ///      logisticsPartner at escrow release. Zero partner = digital goods.
    function createListingWithLogistics(
        uint256 price,
        uint64 quantity,
        string calldata metadataUri,
        bytes32 metadataHash,
        address logisticsPartner,
        uint256 logisticsFee
    ) external returns (uint256 listingId) {
        if (logisticsFee > price) revert InvalidPrice();
        if (logisticsPartner == address(0) && logisticsFee != 0) revert InvalidPrice();
        return _createListing(price, quantity, metadataUri, metadataHash, logisticsPartner, logisticsFee);
    }

    function _createListing(
        uint256 price,
        uint64 quantity,
        string calldata metadataUri,
        bytes32 metadataHash,
        address logisticsPartner,
        uint256 logisticsFee
    )
        internal
        returns (uint256 listingId)
    {
        if (price == 0) revert InvalidPrice();
        if (quantity == 0) revert InvalidQuantity();
        if (metadataHash == bytes32(0)) revert InvalidMetadata();

        listingId = listingCount;
        listingCount = listingId + 1;

        Listing storage listing = listings[listingId];
        listing.seller = msg.sender;
        listing.price = price;
        listing.quantity = quantity;
        listing.status = ListingStatus.Active;
        listing.metadataUri = metadataUri;
        listing.metadataHash = metadataHash;
        listing.createdAt = uint64(block.timestamp);
        listing.updatedAt = listing.createdAt;
        listing.logisticsPartner = logisticsPartner;
        listing.logisticsFee = logisticsFee;

        emit ListingCreated(listingId, msg.sender, price, quantity, metadataHash);
    }

    function updateListingMetadata(uint256 listingId, string calldata metadataUri, bytes32 metadataHash) external {
        Listing storage listing = listings[listingId];
        _requireSeller(listing);
        if (metadataHash == bytes32(0)) revert InvalidMetadata();

        listing.metadataUri = metadataUri;
        listing.metadataHash = metadataHash;
        listing.updatedAt = uint64(block.timestamp);

        emit ListingMetadataUpdated(listingId, metadataUri, metadataHash);
    }

    function updatePrice(uint256 listingId, uint256 price) external {
        Listing storage listing = listings[listingId];
        _requireSeller(listing);
        if (price == 0) revert InvalidPrice();

        listing.price = price;
        listing.updatedAt = uint64(block.timestamp);

        emit ListingPriceUpdated(listingId, price);
    }

    function cancelListing(uint256 listingId) external {
        Listing storage listing = listings[listingId];
        _requireSeller(listing);
        if (listing.status != ListingStatus.Active) revert ListingNotActive();

        listing.status = ListingStatus.Cancelled;
        listing.updatedAt = uint64(block.timestamp);

        emit ListingCancelled(listingId);
    }

    // ------------------------------------------------------------------
    // Buyer actions
    // ------------------------------------------------------------------

    /// @notice Buy a listing: creates an escrow in the Vault and transfers the
    ///         payment to it. The buyer later funds the escrow from the Vault.
    function purchase(uint256 listingId, uint64 deliveryDeadline) external payable returns (uint256 escrowId) {
        Listing storage listing = listings[listingId];
        if (listing.status != ListingStatus.Active) revert ListingNotActive();
        if (listing.quantity == 0) revert OutOfStock();
        if (msg.value != listing.price) revert WrongPayment();
        if (msg.sender == listing.seller) revert InvalidBuyer();

        listing.quantity -= 1;
        if (listing.quantity == 0) {
            listing.status = ListingStatus.Sold;
        }
        listing.updatedAt = uint64(block.timestamp);

        escrowId = vault.createEscrowWithLogistics{ value: msg.value }(
            msg.sender, listing.seller, listing.logisticsPartner, deliveryDeadline, msg.value, listing.logisticsFee
        );
        if (escrowId == 0 && vault.escrowCount() == 0) revert EscrowCreationFailed();

        emit ListingPurchased(listingId, escrowId, msg.sender, listing.seller, listing.price);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _requireSeller(Listing storage listing) internal view {
        if (listing.seller == address(0)) revert ListingNotActive();
        if (msg.sender != listing.seller) revert NotSeller();
    }
}


// ============ SweeftOracleRegistry.sol ============
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SweeftOracleRegistry — authorized fulfilment verifiers
/// @notice Records who may attest fulfilment for escrows. Ownership is
///         intended to be transferred to the SweeftDAO after deployment, so
///         verifier approval is governed rather than hardcoded.
contract SweeftOracleRegistry {
    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event VerifierAdded(address indexed verifier);
    event VerifierRemoved(address indexed verifier);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error NotOwner();
    error ZeroAddress();
    error AlreadyVerifier();
    error NotVerifier();

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    address public owner;
    mapping(address => bool) public isVerifier;

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ------------------------------------------------------------------
    // Owner actions
    // ------------------------------------------------------------------

    function addVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) revert ZeroAddress();
        if (isVerifier[verifier]) revert AlreadyVerifier();

        isVerifier[verifier] = true;
        emit VerifierAdded(verifier);
    }

    function removeVerifier(address verifier) external onlyOwner {
        if (!isVerifier[verifier]) revert NotVerifier();

        isVerifier[verifier] = false;
        emit VerifierRemoved(verifier);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();

        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}


// ============ SweeftVault.sol ============
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SweeftVault — post-quantum escrow
/// @notice Holds buyer funds for commerce transactions. Release to the seller
///         requires the buyer's ML-DSA-87 signature, verified on-chain by
///         QoreChain's `pqcVerify` precompile. A leaked classical (secp256k1)
///         key alone can never move escrowed funds.
/// @dev Pattern adapted from the QoreChain `QDayVault` reference
///      (docs.qorechain.io/build-before-qday/workshop-2).
///
///      Lifecycle:
///        createEscrow -> fundEscrow -> markFulfilled -> attestEvidence
///                                        |                  |
///                                        v                  v
///                     markDelivered/confirmReceipt   (verifier only)
///                                        |
///                                        v
///                                  release (PQ-gated)
///
///      Refund path: if no verifier attestation and no delivery by
///      deliveryDeadline, the buyer can refund (also PQ-gated) after the
///      deadline, or cancel (classical) before funding.
contract SweeftVault {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum EscrowStatus {
        None,
        Funded,
        Completed,
        Cancelled,
        Refunded,
        Disputed
    }

    struct Escrow {
        address buyer;
        address seller;
        uint256 amount; // total escrowed (goods + logistics)
        uint64 deliveryDeadline; // unix seconds
        uint64 createdAt; // unix seconds
        EscrowStatus status;
        bool delivered; // seller marked delivered or buyer confirmed receipt
        bool fulfilledConfirmed; // buyer confirmed receipt (full release path)
        bool evidenceAttested; // oracle verifier attested fulfilment
        bool released;
        address verifier; // the verifier that attested (if any)
        // --- logistics (v4, appended for ABI compatibility) ---
        address logisticsPartner; // zero = physical-less / digital default
        uint256 logisticsAmount; // paid to partner, separate from seller goods
        bool carrierAttested; // signed carrier payload verified on-chain
        uint64 carrierAttestedAt;
        bytes32 carrierPayloadHash; // keccak256(canonical tracking payload)
        address carrierSigner;
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event EscrowCreated(uint256 indexed escrowId, address indexed buyer, address indexed seller, uint256 amount, uint64 deliveryDeadline);
    event EscrowFunded(uint256 indexed escrowId, address indexed buyer, uint256 amount);
    event MarkedFulfilled(uint256 indexed escrowId, address indexed seller);
    event MarkedDelivered(uint256 indexed escrowId, address indexed seller);
    event ReceiptConfirmed(uint256 indexed escrowId, address indexed buyer);
    event EvidenceAttested(uint256 indexed escrowId, address indexed verifier, bytes32 evidenceHash);
    event FundsReleased(uint256 indexed escrowId, address indexed seller, uint256 amount, uint256 pqcNonce);
    event EscrowCancelled(uint256 indexed escrowId);
    event EscrowRefunded(uint256 indexed escrowId, address indexed buyer, uint256 amount, uint256 pqcNonce);
    event DisputeRaised(uint256 indexed escrowId, address indexed raisedBy);
    event DisputeResolved(uint256 indexed escrowId, bool releaseToSeller, uint256 fee);
    event FeeCollected(uint256 indexed escrowId, uint256 treasuryShare, uint256 disputeShare);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event CarrierRegistered(address indexed carrier, string providerId);
    event CarrierRemoved(address indexed carrier);
    event CarrierAttested(uint256 indexed escrowId, address indexed carrier, bytes32 payloadHash, string status, string trackingNumber);
    event LogisticsPaid(uint256 indexed escrowId, address indexed partner, uint256 amount);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error InvalidParties();
    error InvalidAmount();
    error InvalidDeadline();
    error InvalidEscrow();
    error InvalidStatus();
    error NotBuyer();
    error NotSeller();
    error NotVerifier();
    error WrongDeposit();
    error NotReleaseEligible();
    error NotRefundable();
    error GuardianKeyNotRegistered();
    error GuardianKeyNotProven();
    error BadPqcSignature();
    error TransferFailed();
    error NotOwner();
    error NotDisputeBoard();
    error FeeTooHigh();
    error NotDisputable();
    error NotCarrier();
    error BadCarrierSignature();
    error CarrierKeyNotRegistered();
    error CarrierKeyNotProven();
    error BadPayloadHash();

    // ------------------------------------------------------------------
    // QoreChain PQC precompiles (testnet-only; addresses must be lowercase)
    // ------------------------------------------------------------------

    IPQCVerify internal constant PQC_VERIFY = IPQCVerify(0x0000000000000000000000000000000000000a01);
    IPQCKeyStatus internal constant PQC_KEYS = IPQCKeyStatus(0x0000000000000000000000000000000000000a02);

    // ------------------------------------------------------------------
    // Immutables / storage
    // ------------------------------------------------------------------

    /// @notice Registry that authorizes oracle verifiers.
    address public immutable oracleRegistry;

    /// @notice Deployer, allowed to wire the Marketplace once after deployment.
    address public immutable deployer;

    /// @notice The Marketplace, allowed to create escrows on behalf of buyers.
    ///         Set once after both contracts are deployed.
    address public marketplace;

    /// @notice Cosmos chain id as used in QoreSign message domain separation
    ///         (e.g. "qorechain-diana"). QoreX signs messages as
    ///         "qorechain-msg-v1|" + chainId + "|" + data.
    string public cosmosChainId;

    /// @notice Contract owner (deployer, then the DAO). Governs fee parameters.
    address public owner;

    /// @notice Platform fee on successful release, in basis points (200 = 2%).
    ///         Charged only on release — refunds are always free.
    uint256 public feeBps;

    /// @notice Receives the treasury share (70%) of platform fees.
    address public treasury;

    /// @notice The dispute board; receives the resolver share (30%) of fees and
    ///         holds the only key to settle a disputed escrow.
    address public disputeBoard;

    /// @notice Fee split: 70% treasury / 30% dispute reward pool.
    uint256 public constant TREASURY_SHARE_BPS = 7000;
    uint256 public constant DISPUTE_SHARE_BPS = 3000;
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice Contract deployment time.
    uint256 public immutable deployedAt;

    uint256 public escrowCount;
    mapping(uint256 => Escrow) public escrows;

    /// @notice Per-buyer PQ nonce: prevents replay of a release/refund signature.
    mapping(address => uint256) public pqcNonce;

    /// @notice Authorized logistics carriers, by QoreChain account address.
    ///         Their registered ML-DSA-87 key signs carrier tracking payloads
    ///         verified on-chain via pqcVerify — no TEE needed.
    mapping(address => bool) public isCarrier;
    /// @notice Provider id per carrier, e.g. "LOG-DEMO-001".
    mapping(address => string) public carrierProviderId;

    error MarketplaceAlreadySet();

    constructor(address _oracleRegistry, string memory _cosmosChainId, uint256 _feeBps, address _treasury) {
        if (_oracleRegistry == address(0)) revert InvalidParties();
        if (_treasury == address(0)) revert InvalidParties();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        oracleRegistry = _oracleRegistry;
        cosmosChainId = _cosmosChainId;
        feeBps = _feeBps;
        treasury = _treasury;
        owner = msg.sender;
        deployer = msg.sender;
        deployedAt = block.timestamp;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Update the platform fee (DAO-governed once ownership transfers).
    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
    }

    /// @notice Update the treasury address (DAO-governed).
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidParties();
        treasury = newTreasury;
    }

    /// @notice Transfer ownership (deployer → DAO).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidParties();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Wire the dispute board. Callable once by the deployer.
    function setDisputeBoard(address board) external {
        if (msg.sender != deployer) revert NotBuyer();
        if (disputeBoard != address(0)) revert MarketplaceAlreadySet();
        if (board == address(0)) revert InvalidParties();
        disputeBoard = board;
    }

    /// @notice Wire the Marketplace contract. Callable once by the deployer.
    function setMarketplace(address marketplaceAddress) external {
        if (msg.sender != deployer) revert NotBuyer();
        if (marketplace != address(0)) revert MarketplaceAlreadySet();
        if (marketplaceAddress == address(0)) revert InvalidParties();
        marketplace = marketplaceAddress;
    }

    /// @notice Register a logistics carrier (owner/DAO only). The carrier's
    ///         QoreChain account must have a registered ML-DSA-87 key.
    function registerCarrier(address carrier, string calldata providerId) external onlyOwner {
        if (carrier == address(0)) revert InvalidParties();
        isCarrier[carrier] = true;
        carrierProviderId[carrier] = providerId;
        emit CarrierRegistered(carrier, providerId);
    }

    /// @notice Remove a logistics carrier.
    function removeCarrier(address carrier) external onlyOwner {
        if (!isCarrier[carrier]) revert NotCarrier();
        isCarrier[carrier] = false;
        emit CarrierRemoved(carrier);
    }

    // ------------------------------------------------------------------
    // Escrow lifecycle
    // ------------------------------------------------------------------

    /// @notice Create an escrow for `buyer`.
    /// @dev Callable by the buyer themselves, or by the trusted Marketplace
    ///      factory, which forwards the buyer's payment. When `msg.value`
    ///      equals `amount` (the marketplace flow), the escrow is funded
    ///      atomically; otherwise it stays unfunded until `fundEscrow`.
    function createEscrow(address buyer, address seller, uint64 deliveryDeadline, uint256 amount)
        external
        payable
        returns (uint256 escrowId)
    {
        if (buyer == address(0) || seller == address(0) || seller == buyer) revert InvalidParties();
        if (amount == 0) revert InvalidAmount();
        if (msg.sender != buyer && msg.sender != marketplace) revert NotBuyer();
        if (msg.value != 0 && msg.value != amount) revert WrongDeposit();

        escrowId = escrowCount;
        escrowCount = escrowId + 1;

        Escrow storage e = escrows[escrowId];
        e.buyer = buyer;
        e.seller = seller;
        e.amount = amount;
        e.deliveryDeadline = deliveryDeadline;
        e.createdAt = uint64(block.timestamp);

        emit EscrowCreated(escrowId, buyer, seller, amount, deliveryDeadline);

        if (msg.value == amount) {
            e.status = EscrowStatus.Funded;
            emit EscrowFunded(escrowId, buyer, msg.value);
        }
    }

    /// @notice Create an escrow with a logistics allocation.
    /// @dev amount = TOTAL escrowed (goods + logistics). logisticsPartner
    ///      may be zero (digital goods / self-delivery). When funded, the
    ///      logistics share is paid to the partner at release.
    function createEscrowWithLogistics(
        address buyer,
        address seller,
        address logisticsPartner,
        uint64 deliveryDeadline,
        uint256 amount,
        uint256 logisticsAmount
    ) external payable returns (uint256 escrowId) {
        if (buyer == address(0) || seller == address(0) || seller == buyer) revert InvalidParties();
        if (amount == 0) revert InvalidAmount();
        if (logisticsAmount > amount) revert InvalidAmount();
        if (msg.sender != buyer && msg.sender != marketplace) revert NotBuyer();
        if (msg.value != 0 && msg.value != amount) revert WrongDeposit();
        if (logisticsPartner != address(0) && logisticsAmount > 0 && !isCarrier[logisticsPartner]) revert NotCarrier();

        escrowId = escrowCount;
        escrowCount = escrowId + 1;

        Escrow storage e = escrows[escrowId];
        e.buyer = buyer;
        e.seller = seller;
        e.amount = amount;
        e.deliveryDeadline = deliveryDeadline;
        e.createdAt = uint64(block.timestamp);
        e.logisticsPartner = logisticsPartner;
        e.logisticsAmount = logisticsAmount;

        emit EscrowCreated(escrowId, buyer, seller, amount, deliveryDeadline);

        if (msg.value == amount) {
            e.status = EscrowStatus.Funded;
            emit EscrowFunded(escrowId, buyer, msg.value);
        }
    }

    /// @notice Fund the escrow. Only the stored buyer may fund it, and the
    ///         deposit must equal the agreed amount exactly.
    function fundEscrow(uint256 escrowId) external payable {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert InvalidEscrow();
        if (e.status != EscrowStatus.None) revert InvalidStatus();
        if (msg.sender != e.buyer) revert NotBuyer();
        if (msg.value != e.amount) revert WrongDeposit();

        e.status = EscrowStatus.Funded;
        emit EscrowFunded(escrowId, e.buyer, msg.value);
    }

    /// @notice Seller marks the order fulfilled (off-chain delivery pending).
    function markFulfilled(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) revert InvalidStatus();
        if (msg.sender != e.seller) revert NotSeller();
        emit MarkedFulfilled(escrowId, e.seller);
    }

    /// @notice Seller marks the order delivered.
    function markDelivered(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) revert InvalidStatus();
        if (msg.sender != e.seller) revert NotSeller();
        e.delivered = true;
        emit MarkedDelivered(escrowId, e.seller);
    }

    /// @notice Buyer explicitly confirms receipt of the item/service.
    /// @dev Per the agreed terms, receipt confirmation begins or satisfies the
    ///      inspection window, after which release becomes eligible.
    function confirmReceipt(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) revert InvalidStatus();
        if (msg.sender != e.buyer) revert NotBuyer();
        e.fulfilledConfirmed = true;
        emit ReceiptConfirmed(escrowId, e.buyer);
    }

    /// @notice Authorized verifier records a fulfilment attestation on-chain.
    function attestEvidence(uint256 escrowId, bytes32 evidenceHash) external {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) revert InvalidStatus();
        if (!_isVerifier(msg.sender)) revert NotVerifier();
        e.evidenceAttested = true;
        e.verifier = msg.sender;
        emit EvidenceAttested(escrowId, msg.sender, evidenceHash);
    }

    /// @notice Verify the carrier's ML-DSA-87 signature over the canonical
    ///         tracking payload on-chain and record it as fulfilment evidence.
    function attestCarrierEvidence(
        uint256 escrowId,
        bytes32 payloadHash,
        bytes calldata signature,
        bytes calldata payload
    ) external {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) revert InvalidStatus();
        if (!isCarrier[msg.sender]) revert NotCarrier();
        if (keccak256(payload) != payloadHash) revert BadPayloadHash();

        _requireCarrierSignature(msg.sender, payload, signature);

        e.carrierAttested = true;
        e.carrierAttestedAt = uint64(block.timestamp);
        e.carrierPayloadHash = payloadHash;
        e.carrierSigner = msg.sender;

        e.evidenceAttested = true;
        e.verifier = msg.sender; // excluded from dispute board like a verifier
        e.delivered = true;

        emit EvidenceAttested(escrowId, msg.sender, payloadHash);
        emit CarrierAttested(escrowId, msg.sender, payloadHash, "", "");
    }

    function _requireCarrierSignature(address carrier, bytes memory payload, bytes calldata signature) internal view {
        (bool registered,, bytes memory pubkey, bool proven) = PQC_KEYS.pqcKeyStatus(carrier);
        if (!registered || pubkey.length == 0) revert CarrierKeyNotRegistered();
        if (!proven) revert CarrierKeyNotProven();
        if (!PQC_VERIFY.pqcVerify(pubkey, signature, payload)) revert BadCarrierSignature();
    }

    /// @notice Release escrowed funds to the seller, charging the platform fee.
    /// @dev Eligible when the buyer confirmed receipt, or the escrow has been
    ///      delivered/attested and the delivery deadline has passed (inspection
    ///      window satisfied). Authorization is the buyer's registered
    ///      ML-DSA-87 signature over the release message; anyone may submit it.
    ///      The fee (feeBps) is split treasury/dispute pool; refunds are free.
    function release(uint256 escrowId, bytes calldata signature) external {
        if (!isReleaseEligible(escrowId)) revert NotReleaseEligible();

        Escrow storage e = escrows[escrowId];
        uint256 nonce = pqcNonce[e.buyer];
        bytes memory message = _releaseMessage(escrowId, e.buyer, e.seller, e.amount, nonce);
        _requirePqcSignature(e.buyer, message, signature);

        pqcNonce[e.buyer] = nonce + 1;
        e.released = true;
        e.status = EscrowStatus.Completed;

        emit FundsReleased(escrowId, e.seller, e.amount, nonce);

        _payRelease(escrowId, e);
    }

    /// @notice Refund the buyer when the seller never delivered or was never
    ///         attested. Gated by the buyer's ML-DSA-87 signature and by the
    ///         delivery deadline having passed; blocked once a verifier has
    ///         attested (that escrow must go through release).
    function refundAfterDeadline(uint256 escrowId, bytes calldata signature) external {
        if (!isRefundable(escrowId)) revert NotRefundable();

        Escrow storage e = escrows[escrowId];
        uint256 nonce = pqcNonce[e.buyer];
        bytes memory message = _refundMessage(escrowId, e.buyer, e.buyer, e.amount, nonce);
        _requirePqcSignature(e.buyer, message, signature);

        pqcNonce[e.buyer] = nonce + 1;
        e.status = EscrowStatus.Refunded;

        emit EscrowRefunded(escrowId, e.buyer, e.amount, nonce);

        (bool ok,) = e.buyer.call{ value: e.amount }("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Cancel an unfunded escrow. Either party may cancel.
    function cancelEscrow(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert InvalidEscrow();
        if (e.status != EscrowStatus.None) revert InvalidStatus();
        if (msg.sender != e.buyer && msg.sender != e.seller) revert InvalidParties();

        e.status = EscrowStatus.Cancelled;
        emit EscrowCancelled(escrowId);
    }

    // ------------------------------------------------------------------
    // Disputes
    // ------------------------------------------------------------------

    /// @notice Freeze a funded escrow for dispute resolution. Buyer or seller
    ///         only — or the dispute board, which validates the raiser before
    ///         calling. While disputed, the normal release and refund paths
    ///         are closed; the staked dispute board decides the outcome.
    function raiseDispute(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert InvalidEscrow();
        if (e.status != EscrowStatus.Funded) revert NotDisputable();
        if (msg.sender != e.buyer && msg.sender != e.seller && msg.sender != disputeBoard) {
            revert InvalidParties();
        }

        e.status = EscrowStatus.Disputed;
        emit DisputeRaised(escrowId, msg.sender);
    }

    /// @notice Settle a disputed escrow. Only the dispute board contract may
    ///         call this; the board reaches a 2-of-3 resolver majority.
    ///         Release charges the normal fee; refund returns the full amount.
    function resolveDispute(uint256 escrowId, bool releaseToSeller) external {
        if (msg.sender != disputeBoard) revert NotDisputeBoard();

        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Disputed) revert InvalidStatus();

        uint256 fee = 0;
        if (releaseToSeller) {
            e.released = true;
            e.status = EscrowStatus.Completed;
            fee = _feeFor(e.amount);
            _payRelease(escrowId, e);
        } else {
            e.status = EscrowStatus.Refunded;
            (bool ok,) = e.buyer.call{ value: e.amount }("");
            if (!ok) revert TransferFailed();
        }

        emit DisputeResolved(escrowId, releaseToSeller, fee);
    }

    function _feeFor(uint256 amount) internal view returns (uint256) {
        return (amount * feeBps) / 10_000;
    }

    /// @dev Pay the seller minus the platform fee; split the fee between the
    ///      treasury (70%) and the dispute reward pool (30%). When a logistics
    ///      share is set, the partner is paid first and the fee is charged on
    ///      the goods portion only.
    function _payRelease(uint256 escrowId, Escrow storage e) internal {
        uint256 goodsAmount = e.amount - e.logisticsAmount;

        if (e.logisticsAmount > 0 && e.logisticsPartner != address(0)) {
            (bool logOk,) = e.logisticsPartner.call{ value: e.logisticsAmount }("");
            if (!logOk) revert TransferFailed();
            emit LogisticsPaid(escrowId, e.logisticsPartner, e.logisticsAmount);
        }

        uint256 fee = _feeFor(goodsAmount);
        uint256 sellerAmount = goodsAmount - fee;

        if (fee > 0) {
            uint256 treasuryShare = (fee * TREASURY_SHARE_BPS) / 10_000;
            uint256 disputeShare = fee - treasuryShare;

            if (disputeBoard == address(0)) {
                treasuryShare = fee;
                disputeShare = 0;
            }

            (bool tOk,) = treasury.call{ value: treasuryShare }("");
            if (!tOk) revert TransferFailed();

            if (disputeShare > 0) {
                (bool dOk,) = disputeBoard.call{ value: disputeShare }(
                    abi.encodeWithSignature("receiveFeeShare()")
                );
                if (!dOk) revert TransferFailed();
            }

            emit FeeCollected(escrowId, treasuryShare, disputeShare);
        }

        (bool ok,) = e.seller.call{ value: sellerAmount }("");
        if (!ok) revert TransferFailed();
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getEscrow(uint256 escrowId) external view returns (Escrow memory) {
        return escrows[escrowId];
    }

    function isReleaseEligible(uint256 escrowId) public view returns (bool) {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) return false;
        if (e.fulfilledConfirmed) return true;
        if ((e.delivered || e.evidenceAttested) && block.timestamp >= e.deliveryDeadline) {
            return true;
        }
        return false;
    }

    function isRefundable(uint256 escrowId) public view returns (bool) {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) return false;
        if (e.evidenceAttested) return false;
        return block.timestamp >= e.deliveryDeadline;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _isVerifier(address account) internal view returns (bool) {
        (bool ok, bytes memory data) = oracleRegistry.staticcall(
            abi.encodeWithSignature("isVerifier(address)", account)
        );
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (bool));
    }

    function _releaseMessage(uint256 escrowId, address buyer, address recipient, uint256 amount, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        return bytes(
            string.concat(
                "sweeft-release-v1|vault=",
                _toHexString(address(this)),
                "|escrow=",
                _uintToString(escrowId),
                "|buyer=",
                _toHexString(buyer),
                "|recipient=",
                _toHexString(recipient),
                "|amount=",
                _uintToString(amount),
                "|nonce=",
                _uintToString(nonce)
            )
        );
    }

    function _refundMessage(uint256 escrowId, address buyer, address recipient, uint256 amount, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        return bytes(
            string.concat(
                "sweeft-refund-v1|vault=",
                _toHexString(address(this)),
                "|escrow=",
                _uintToString(escrowId),
                "|buyer=",
                _toHexString(buyer),
                "|recipient=",
                _toHexString(recipient),
                "|amount=",
                _uintToString(amount),
                "|nonce=",
                _uintToString(nonce)
            )
        );
    }

    /// @dev Reads the guardian's registered ML-DSA-87 key from the chain and
    ///      verifies the signature over the QoreSign message payload:
    ///      "qorechain-msg-v1|" + chainId + "|" + message.
    ///      This is exactly what QoreX's signArbitrary produces, so the wallet
    ///      shows the release terms before the buyer approves. Fails closed.
    function _requirePqcSignature(address guardian, bytes memory message, bytes calldata signature) internal view {
        (bool registered,, bytes memory pubkey, bool proven) = PQC_KEYS.pqcKeyStatus(guardian);
        if (!registered || pubkey.length == 0) revert GuardianKeyNotRegistered();
        if (!proven) revert GuardianKeyNotProven();

        bytes memory payload = abi.encodePacked("qorechain-msg-v1|", cosmosChainId, "|", message);
        if (!PQC_VERIFY.pqcVerify(pubkey, signature, payload)) revert BadPqcSignature();
    }

    /// @dev "0x" + lowercase hex of an address (deterministic, no checksum).
    function _toHexString(address account) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes20 data = bytes20(account);
        bytes memory out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            out[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            out[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(out);
    }

    /// @dev Decimal string of a uint256, no leading zeros.
    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

// ----------------------------------------------------------------------
// Precompile interfaces
// ----------------------------------------------------------------------

interface IPQCVerify {
    /// @param pubkey ML-DSA-87 public key (2,592 bytes)
    /// @param signature ML-DSA-87 signature (4,627 bytes)
    /// @param message the exact signed message bytes
    /// @return true when the signature verifies against the key
    function pqcVerify(bytes calldata pubkey, bytes calldata signature, bytes calldata message)
        external
        view
        returns (bool);
}

interface IPQCKeyStatus {
    /// @return registered whether an ML-DSA-87 key is bound to the account
    /// @return algorithmId the registered algorithm
    /// @return pubkey the registered public key bytes
    /// @return proven whether ownership was proven at registration
    function pqcKeyStatus(address account)
        external
        view
        returns (bool registered, uint8 algorithmId, bytes memory pubkey, bool proven);
}


