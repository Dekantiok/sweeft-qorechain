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
    /// @notice Board size is hard-capped at 3 members — the settlement loop
    ///         is bounded by design and cannot be griefed by an unbounded
    ///         number of resolvers.
    uint256 internal constant MAX_BOARD_SIZE = 3;
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

    function _settle(uint256 disputeId, Dispute storage d, bool releaseToSeller) internal {
        d.state = DisputeState.Resolved;
        d.releaseToSeller = releaseToSeller;

        // Release the resolvers from this board.
        for (uint256 i = 0; i < d.memberCount; i++) {
            address member = d.members[i];
            if (activeBoards[member] > 0) {
                activeBoards[member] -= 1;
            }
        }

        vault.resolveDispute(d.escrowId, releaseToSeller);
        emit DisputeSettled(disputeId, d.escrowId, releaseToSeller);
    }

    // ------------------------------------------------------------------
    // Rewards
    // ------------------------------------------------------------------

    /// @notice The reward a voting resolver earns for a dispute: 10% of the
    ///         escrow's platform fee (the 30% resolver share split three ways),
    ///         paid from the accumulated reward pool. Fee is on goods only.
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
