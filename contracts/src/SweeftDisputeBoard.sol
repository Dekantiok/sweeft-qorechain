// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SweeftVault } from "./SweeftVault.sol";

/// @title SweeftDisputeBoard — staked resolver panels for escrow disputes
/// @notice Anyone who stakes at least the per-dispute minimum may join an open
///         dispute (first three eligible resolvers form the board). Parties,
///         the verifier and the carrier are excluded. A 2-of-3 majority settles
///         the escrow through the Vault.
///
///         Hardening (v5):
///           - stake required scales with escrow value (base + ~1%)
///           - minority voters and non-voters are slashed at settlement
///           - the raiser posts a bond, returned if their side prevails
///           - resolver locks extend past settlement by an appeal window
///           - the expiry fallback is a deterministic rule, not owner discretion
///           - rewards come from this dispute's own fee; refunds pay no reward,
///             so the pool cannot be drained by fee-less resolutions
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
        uint64 unlockAt;
        DisputeState state;
        bool releaseToSeller; // final outcome
        uint8 votesForRelease;
        uint8 votesForRefund;
        uint8 memberCount;
        uint256 bond;
        address[3] members;
        mapping(address => bool) isMember;
        mapping(address => bool) hasVoted;
        mapping(address => bool) votedRelease;
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event Staked(address indexed account, uint256 amount, uint256 total);
    event UnstakeRequested(address indexed account, uint64 availableAt);
    event StakeWithdrawn(address indexed account, uint256 amount);
    event Slashed(address indexed account, uint256 amount);
    event DisputeOpened(uint256 indexed disputeId, uint256 indexed escrowId, address indexed raiser, uint64 votingEndsAt, uint256 bond);
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
    error BondTooLow();
    error TransferFailed();

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    SweeftVault public immutable vault;
    address public owner;

    /// @notice Base minimum stake to serve on a board (20 QOR).
    uint256 public minStake = 20 ether;
    /// @notice Additional stake proportional to escrow value (100 = 1%).
    uint256 public constant STAKE_BPS = 100;
    /// @notice Fraction of a resolver's stake slashed for a wrong/absent vote.
    uint256 public constant SLASH_BPS = 1000; // 10%
    /// @notice Raiser bond as a fraction of escrow value, with a floor.
    uint256 public constant DISPUTE_BOND_BPS = 100; // 1%
    uint256 public constant MIN_DISPUTE_BOND = 0.1 ether;

    uint256 internal constant MAX_BOARD_SIZE = 3;

    uint64 public unstakeCooldown = 1 hours;
    uint64 public votingPeriod = 48 hours;
    /// @notice Minimum lock after settlement, to leave room for an appeal.
    uint64 public appealWindow = 1 days;

    mapping(address => uint256) public stakeOf;
    mapping(address => uint64) public unstakeAvailableAt;
    /// @notice Earliest time a resolver's stake may be released (join/settle).
    mapping(address => uint64) public lockedUntil;

    /// @notice Accumulated resolver reward pool — fee shares from the Vault.
    uint256 public rewardPool;

    uint256 public disputeCount;
    mapping(uint256 => Dispute) private disputes;

    uint256 private _lock = 1;

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

    modifier nonReentrant() {
        if (_lock != 1) revert DisputeNotOpen();
        _lock = 2;
        _;
        _lock = 1;
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

    function setAppealWindow(uint64 newWindow) external onlyOwner {
        appealWindow = newWindow;
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

    /// @notice Begin unstaking. Blocked while any lock is active.
    function requestUnstake() external {
        if (stakeOf[msg.sender] == 0) revert NoStake();
        if (block.timestamp < lockedUntil[msg.sender]) revert StakeLocked();
        unstakeAvailableAt[msg.sender] = uint64(block.timestamp) + unstakeCooldown;
        emit UnstakeRequested(msg.sender, unstakeAvailableAt[msg.sender]);
    }

    function withdrawStake() external nonReentrant {
        uint256 amount = stakeOf[msg.sender];
        if (amount == 0) revert NoStake();
        if (block.timestamp < lockedUntil[msg.sender]) revert StakeLocked();
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

    /// @notice Minimum stake a resolver must hold to join a dispute over an
    ///         escrow of `escrowAmount`.
    function minStakeFor(uint256 escrowAmount) public view returns (uint256) {
        return minStake + (escrowAmount * STAKE_BPS) / 10_000;
    }

    /// @notice Raiser bond for an escrow of `escrowAmount`.
    function disputeBondFor(uint256 escrowAmount) public pure returns (uint256) {
        uint256 bond = (escrowAmount * DISPUTE_BOND_BPS) / 10_000;
        return bond < MIN_DISPUTE_BOND ? MIN_DISPUTE_BOND : bond;
    }

    /// @notice Open a dispute for a funded escrow, posting the raiser bond.
    function openDispute(uint256 escrowId) external payable returns (uint256 disputeId) {
        SweeftVault.Escrow memory escrow = vault.getEscrow(escrowId);
        if (escrow.buyer == address(0)) revert UnknownDispute();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert ExcludedParty();
        uint256 requiredBond = disputeBondFor(escrow.amount);
        if (msg.value < requiredBond) revert BondTooLow();

        vault.raiseDispute(escrowId);

        disputeId = disputeCount;
        disputeCount = disputeId + 1;

        Dispute storage d = disputes[disputeId];
        d.escrowId = escrowId;
        d.raiser = msg.sender;
        d.openedAt = uint64(block.timestamp);
        d.votingEndsAt = uint64(block.timestamp) + votingPeriod;
        d.unlockAt = d.votingEndsAt + appealWindow;
        d.state = DisputeState.Open;
        d.bond = msg.value;

        emit DisputeOpened(disputeId, escrowId, msg.sender, d.votingEndsAt, msg.value);
    }

    /// @notice Join an open dispute's board. First three eligible resolvers,
    ///         each holding at least `minStakeFor(escrow.amount)`.
    function joinDispute(uint256 disputeId) external {
        Dispute storage d = disputes[disputeId];
        if (d.state == DisputeState.None) revert UnknownDispute();
        if (d.state != DisputeState.Open) revert DisputeNotOpen();
        if (block.timestamp >= d.votingEndsAt) revert VotingClosed();
        if (d.memberCount >= MAX_BOARD_SIZE) revert BoardFull();
        if (d.isMember[msg.sender]) revert AlreadyMember();

        SweeftVault.Escrow memory escrow = vault.getEscrow(d.escrowId);
        uint256 required = minStakeFor(escrow.amount);
        if (stakeOf[msg.sender] < required) revert StakeTooLow();

        if (msg.sender == escrow.buyer || msg.sender == escrow.seller) revert ExcludedParty();
        if (escrow.verifier != address(0) && msg.sender == escrow.verifier) revert ExcludedParty();
        if (escrow.logisticsPartner != address(0) && msg.sender == escrow.logisticsPartner) revert ExcludedParty();

        d.isMember[msg.sender] = true;
        d.members[d.memberCount] = msg.sender;
        d.memberCount += 1;
        _extendLock(msg.sender, d.votingEndsAt + appealWindow);

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
        d.votedRelease[msg.sender] = releaseToSeller;
        if (releaseToSeller) {
            d.votesForRelease += 1;
        } else {
            d.votesForRefund += 1;
        }
        emit ResolverVoted(disputeId, msg.sender, releaseToSeller);

        if (d.votesForRelease >= 2) {
            _settle(disputeId, d, true, false);
        } else if (d.votesForRefund >= 2) {
            _settle(disputeId, d, false, false);
        }
    }

    /// @notice Permissionless liveness fallback when a panel reaches its
    ///         deadline without a majority. The outcome is the deterministic
    ///         default: release if fulfilment was claimed (delivered or carrier
    ///         attested), otherwise refund the buyer. No owner discretion.
    function resolveExpired(uint256 disputeId) external {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Open) revert DisputeNotOpen();
        if (block.timestamp < d.votingEndsAt) revert VotingStillOpen();
        if (d.votesForRelease >= 2 || d.votesForRefund >= 2) revert NoMajority();

        SweeftVault.Escrow memory escrow = vault.getEscrow(d.escrowId);
        bool releaseToSeller = escrow.delivered || escrow.carrierAttested;
        _settle(disputeId, d, releaseToSeller, true);
    }

    /// @param slashNonVoters true when settling by expiry (members who never
    ///        voted failed their duty); false when the panel settled by
    ///        majority, since the dissenting member may not have had a turn.
    function _settle(uint256 disputeId, Dispute storage d, bool releaseToSeller, bool slashNonVoters) internal {
        d.state = DisputeState.Resolved;
        d.releaseToSeller = releaseToSeller;

        // Slash resolvers who voted against the outcome (and, on expiry,
        // those who never voted).
        for (uint256 i = 0; i < d.memberCount; i++) {
            address member = d.members[i];
            bool correct = d.hasVoted[member] && (d.votedRelease[member] == releaseToSeller);
            bool shouldSlash = d.hasVoted[member] ? !correct : slashNonVoters;
            if (shouldSlash) {
                _slash(member);
            }
            _extendLock(member, uint64(block.timestamp) + appealWindow);
        }

        _settleBond(d, releaseToSeller);

        vault.resolveDispute(d.escrowId, releaseToSeller);
        emit DisputeSettled(disputeId, d.escrowId, releaseToSeller);
    }

    function _slash(address member) internal {
        uint256 stake = stakeOf[member];
        if (stake == 0) return;
        uint256 slash = (stake * SLASH_BPS) / 10_000;
        if (slash == 0) return;
        stakeOf[member] = stake - slash;
        rewardPool += slash;
        emit Slashed(member, slash);
    }

    function _settleBond(Dispute storage d, bool releaseToSeller) internal {
        if (d.bond == 0) return;
        bool raiserIsBuyer = d.raiser == vault.getEscrow(d.escrowId).buyer;
        bool raiserWins = raiserIsBuyer ? !releaseToSeller : releaseToSeller;
        if (raiserWins) {
            (bool ok,) = d.raiser.call{ value: d.bond }("");
            if (!ok) {
                rewardPool += d.bond;
            }
        } else {
            // A losing raiser's bond is forfeited to the resolver reward pool.
            rewardPool += d.bond;
        }
    }

    function _extendLock(address member, uint64 until) internal {
        if (until > lockedUntil[member]) {
            lockedUntil[member] = until;
        }
    }

    // ------------------------------------------------------------------
    // Rewards
    // ------------------------------------------------------------------

    /// @notice Per-resolver reward for a settled, released dispute. Funded by
    ///         this escrow's own fee (30% resolver share, split across voters).
    ///         A refund collects no fee, so it pays no reward — the pool cannot
    ///         be drained by fee-less resolutions.
    function resolverReward(uint256 disputeId) public view returns (uint256) {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Resolved || !d.releaseToSeller) return 0;

        uint256 voters = uint256(d.votesForRelease) + uint256(d.votesForRefund);
        if (voters == 0) return 0;

        SweeftVault.Escrow memory escrow = vault.getEscrow(d.escrowId);
        uint256 goods = escrow.amount - escrow.logisticsAmount;
        uint256 fee = (goods * vault.escrowFeeBps(d.escrowId)) / 10_000;
        return ((fee * 3_000) / 10_000) / voters;
    }

    mapping(uint256 => mapping(address => bool)) public rewardClaimed;

    function claimReward(uint256 disputeId) external nonReentrant {
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
            uint64 unlockAt,
            DisputeState state,
            bool releaseToSeller,
            uint8 votesForRelease,
            uint8 votesForRefund,
            uint8 memberCount,
            uint256 bond,
            address[3] memory members
        )
    {
        Dispute storage d = disputes[disputeId];
        return (
            d.escrowId,
            d.raiser,
            d.openedAt,
            d.votingEndsAt,
            d.unlockAt,
            d.state,
            d.releaseToSeller,
            d.votesForRelease,
            d.votesForRefund,
            d.memberCount,
            d.bond,
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
