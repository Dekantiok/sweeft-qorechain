// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SweeftVault } from "./SweeftVault.sol";

/// @title SweeftDisputeBoard — staked, randomly-drawn resolver panels
/// @notice Resolvers stake into a pool. A dispute opens a short join window,
///         after which anyone may draw a 3-resolver panel pseudo-randomly from
///         the pool (parties, the verifier and the carrier are excluded). A
///         2-of-3 majority records a decision. The decision becomes payable
///         only after the appeal window: either party may appeal to a larger
///         5-resolver panel, which can overturn the first decision and slash
///         the first panel's stake if it does. Without an appeal, anyone may
///         finalize and settle the escrow.
///
///         Hardening (v6) — addresses the residual review:
///           - N-2: the expiry default releases only on PROOF (verifier
///             threshold or carrier DELIVERED); otherwise it refunds. The
///             seller's markDelivered claim never releases funds.
///           - N-3: panels are drawn from a staked pool (not first-come), stake
///             must be near the escrow value, resolvers are paid a fixed fee
///             from the raiser's bond for EITHER outcome, and a real appeal to
///             a larger panel exists (with a first-panel slash on overturn).
///           - N-4: stranded funds are sweepable to a treasury, slashed stake is
///             reward-funding not dead weight, and the board can pull the credit
///             the Vault accrues for it on a failed fee push.
contract SweeftDisputeBoard {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum DisputeState {
        None,
        Open, // first panel voting
        Resolved, // decision recorded; appeal window running
        Appealed, // appeal panel voting
        Final // escrow settled, rewards claimable
    }

    struct Dispute {
        uint256 escrowId;
        address raiser;
        uint64 openedAt;
        uint64 joinEndsAt;
        uint64 votingEndsAt;
        uint64 resolvedAt;
        uint64 unlockAt; // appeal deadline after a first decision
        DisputeState state;
        bool panelSelected;
        bool releaseToSeller; // current decision
        uint8 votesForRelease;
        uint8 votesForRefund;
        uint8 memberCount;
        uint256 bond; // raiser bond (held until finalization)
        uint256 rewardPerVoter; // first panel fixed fee
        address[3] members;
        // --- appeal round ---
        bool appealSelected;
        address appellant;
        uint8 appealVotesForRelease;
        uint8 appealVotesForRefund;
        uint8 appealMemberCount;
        uint256 appealBond;
        uint256 appealRewardPerVoter;
        uint64 appealVotingEndsAt;
        address[5] appealMembers;
        mapping(address => uint8) roundOf; // 1 = first panel, 2 = appeal panel
        mapping(address => bool) hasVoted;
        mapping(address => bool) votedRelease;
        mapping(address => bool) claimed;
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event Staked(address indexed account, uint256 amount, uint256 total);
    event UnstakeRequested(address indexed account, uint64 availableAt);
    event StakeWithdrawn(address indexed account, uint256 amount);
    event Slashed(address indexed account, uint256 amount, uint8 round);
    event DisputeOpened(uint256 indexed disputeId, uint256 indexed escrowId, address indexed raiser, uint64 joinEndsAt, uint64 votingEndsAt, uint256 bond);
    event PanelSelected(uint256 indexed disputeId, address[3] members, uint8 count);
    event ResolverVoted(uint256 indexed disputeId, address indexed resolver, bool releaseToSeller);
    event DisputeDecisionRecorded(uint256 indexed disputeId, bool releaseToSeller, uint64 finalizeAfter);
    event AppealOpened(uint256 indexed disputeId, uint256 indexed escrowId, address indexed appellant, uint64 votingEndsAt, uint256 bond);
    event AppealPanelSelected(uint256 indexed disputeId, address[5] members, uint8 count);
    event AppealResolverVoted(uint256 indexed disputeId, address indexed resolver, bool releaseToSeller);
    event AppealResolved(uint256 indexed disputeId, bool releaseToSeller, bool overturned);
    event DisputeSettled(uint256 indexed disputeId, uint256 indexed escrowId, bool releaseToSeller);
    event RewardClaimed(uint256 indexed disputeId, address indexed resolver, uint256 amount, uint8 round);
    event BondRefunded(uint256 indexed disputeId, address indexed raiser, uint256 amount);
    event RewardFunded(uint256 indexed disputeId, uint256 amount);
    event Swept(address indexed to, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

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
    error JoinWindowActive();
    error PanelAlreadySelected();
    error PanelNotSelected();
    error PanelUnavailable();
    error TransferFailed();
    error AppealWindowClosed();
    error AppealWindowActive();
    error NotFinal();
    error NotParty();

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    SweeftVault public immutable vault;
    address public owner;
    address public treasury;

    /// @notice Base minimum stake to serve on a board.
    uint256 public minStake = 20 ether;
    /// @notice A resolver must also stake at least the escrow value, so
    ///         capturing a dispute costs what is at stake (N-3).
    uint256 public constant ESCROW_STAKE_RATIO = 10_000; // 100% of escrow value
    /// @notice Fraction of a resolver's stake slashed for not voting (N-3).
    uint256 public constant SLASH_BPS = 1000; // 10%
    /// @notice Fraction of a first-panel voter's stake slashed when an appeal
    ///         overturns their decision.
    uint256 public constant APPEAL_OVERTURN_SLASH_BPS = 5000; // 50%
    /// @notice Raiser bond as a fraction of escrow value, with a floor.
    uint256 public constant DISPUTE_BOND_BPS = 100; // 1%
    uint256 public constant MIN_DISPUTE_BOND = 0.1 ether;
    /// @notice An appeal bond is a multiple of the original raiser bond.
    uint256 public constant APPEAL_BOND_MULTIPLIER = 2;
    /// @notice Share of the raiser bond that pays first-panel resolvers.
    uint256 public constant RESOLVER_FEE_BPS = 2000; // 20%
    /// @notice Share of the appeal bond that pays the appeal panel.
    uint256 public constant APPEAL_FEE_BPS = 3000; // 30%

    uint256 public constant MAX_BOARD_SIZE = 3;
    uint256 public constant APPEAL_BOARD_SIZE = 5;

    uint64 public joinWindow = 6 hours;
    uint64 public votingPeriod = 48 hours;
    /// @notice Time either party has to appeal a first decision before it can
    ///         be finalized. This is a real appeal window (not just a lock).
    uint64 public appealWindow = 2 days;
    uint64 public unstakeCooldown = 1 hours;

    mapping(address => uint256) public stakeOf;
    mapping(address => uint64) public unstakeAvailableAt;
    mapping(address => uint64) public lockedUntil;

    /// @notice Staked resolver pool (swap-and-pop on withdrawal).
    address[] public resolverPool;
    mapping(address => uint256) public poolIndexPlusOne; // 0 = not in pool

    /// @notice Reward funding: fee shares from the Vault plus slashed stake.
    uint256 public rewardPool;

    uint256 public disputeCount;
    mapping(uint256 => Dispute) private disputes;

    uint256 private _lock = 1;

    function receiveFeeShare() external payable {
        if (msg.sender != address(vault)) revert NotVault();
        rewardPool += msg.value;
    }

    constructor(address vaultAddress, address treasuryAddress) {
        if (vaultAddress == address(0) || treasuryAddress == address(0)) revert ZeroAmount();
        vault = SweeftVault(vaultAddress);
        treasury = treasuryAddress;
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

    function setJoinWindow(uint64 newWindow) external onlyOwner {
        joinWindow = newWindow;
    }

    function setAppealWindow(uint64 newWindow) external onlyOwner {
        appealWindow = newWindow;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAmount();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
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
        if (poolIndexPlusOne[msg.sender] == 0) {
            resolverPool.push(msg.sender);
            poolIndexPlusOne[msg.sender] = resolverPool.length; // 1-based
        }
        emit Staked(msg.sender, msg.value, stakeOf[msg.sender]);
    }

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
        _removeFromPool(msg.sender);
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit StakeWithdrawn(msg.sender, amount);
    }

    function _removeFromPool(address account) internal {
        uint256 idxPlusOne = poolIndexPlusOne[account];
        if (idxPlusOne == 0) return;
        uint256 idx = idxPlusOne - 1;
        uint256 lastIdx = resolverPool.length - 1;
        if (idx != lastIdx) {
            address last = resolverPool[lastIdx];
            resolverPool[idx] = last;
            poolIndexPlusOne[last] = idx + 1;
        }
        resolverPool.pop();
        poolIndexPlusOne[account] = 0;
    }

    // ------------------------------------------------------------------
    // Disputes
    // ------------------------------------------------------------------

    function minStakeFor(uint256 escrowAmount) public view returns (uint256) {
        return minStake + (escrowAmount * ESCROW_STAKE_RATIO) / 10_000;
    }

    function disputeBondFor(uint256 escrowAmount) public pure returns (uint256) {
        uint256 bond = (escrowAmount * DISPUTE_BOND_BPS) / 10_000;
        return bond < MIN_DISPUTE_BOND ? MIN_DISPUTE_BOND : bond;
    }

    /// @notice Bond required to appeal a first decision (2x the raiser bond).
    function appealBondFor(uint256 escrowAmount) public pure returns (uint256) {
        return disputeBondFor(escrowAmount) * APPEAL_BOND_MULTIPLIER;
    }

    /// @notice Open a dispute for a funded escrow, posting the raiser bond.
    ///         A join window opens; the panel is then drawn from the pool.
    function openDispute(uint256 escrowId) external payable returns (uint256 disputeId) {
        SweeftVault.Escrow memory escrow = vault.getEscrow(escrowId);
        if (escrow.buyer == address(0)) revert UnknownDispute();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert ExcludedParty();
        uint256 requiredBond = disputeBondFor(escrow.amount);
        if (msg.value < requiredBond) revert BondTooLow();

        // The board is the only caller allowed to freeze the escrow (N-1).
        vault.raiseDispute(escrowId);

        disputeId = disputeCount;
        disputeCount = disputeId + 1;

        Dispute storage d = disputes[disputeId];
        d.escrowId = escrowId;
        d.raiser = msg.sender;
        d.openedAt = uint64(block.timestamp);
        d.joinEndsAt = uint64(block.timestamp) + joinWindow;
        d.votingEndsAt = d.joinEndsAt + votingPeriod;
        d.state = DisputeState.Open;
        d.bond = msg.value;

        emit DisputeOpened(disputeId, escrowId, msg.sender, d.joinEndsAt, d.votingEndsAt, msg.value);
    }

    /// @notice Draw the first resolver panel from the staked pool after the
    ///         join window. Permissionless. Pseudo-random via `block.prevrandao`
    ///         — testnet grade (a validator can bias it); a commit-reveal or VRF
    ///         source is future work. Parties/verifier/carrier are excluded.
    function selectPanel(uint256 disputeId) external {
        Dispute storage d = disputes[disputeId];
        if (d.state == DisputeState.None) revert UnknownDispute();
        if (d.state != DisputeState.Open) revert DisputeNotOpen();
        if (d.panelSelected) revert PanelAlreadySelected();
        if (block.timestamp < d.joinEndsAt) revert JoinWindowActive();
        if (block.timestamp >= d.votingEndsAt) revert VotingClosed();

        d.panelSelected = true;
        SweeftVault.Escrow memory escrow = vault.getEscrow(d.escrowId);
        uint8 chosen = _drawPanel(d, escrow, MAX_BOARD_SIZE, 1);
        d.memberCount = chosen;
        emit PanelSelected(disputeId, d.members, chosen);
    }

    /// @notice Cast a first-panel vote. A 2-of-3 majority records a decision;
    ///         the decision is payable after the appeal window (see finalize).
    function castVote(uint256 disputeId, bool releaseToSeller) external nonReentrant {
        Dispute storage d = disputes[disputeId];
        if (d.state == DisputeState.None) revert UnknownDispute();
        if (d.state != DisputeState.Open) revert DisputeNotOpen();
        if (!d.panelSelected) revert PanelNotSelected();
        if (block.timestamp >= d.votingEndsAt) revert VotingClosed();
        if (d.roundOf[msg.sender] != 1) revert NotMember();
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
            _recordFirstOutcome(disputeId, d, true);
        } else if (d.votesForRefund >= 2) {
            _recordFirstOutcome(disputeId, d, false);
        }
    }

    /// @notice Permissionless liveness fallback when a panel reaches its
    ///         deadline without a majority. The default resolves on PROOF:
    ///         release only if the escrow has verifier-threshold or carrier
    ///         DELIVERED evidence, otherwise refund the buyer (N-2). The
    ///         decision can still be appealed.
    function resolveExpired(uint256 disputeId) external nonReentrant {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Open) revert DisputeNotOpen();
        if (block.timestamp < d.votingEndsAt) revert VotingStillOpen();
        if (d.votesForRelease >= 2 || d.votesForRefund >= 2) revert NoMajority();

        SweeftVault.Escrow memory escrow = vault.getEscrow(d.escrowId);
        bool releaseToSeller = escrow.carrierDelivered || escrow.evidenceAttested;
        _recordFirstOutcome(disputeId, d, releaseToSeller);
    }

    function _recordFirstOutcome(uint256 disputeId, Dispute storage d, bool releaseToSeller) internal {
        d.state = DisputeState.Resolved;
        d.releaseToSeller = releaseToSeller;
        d.resolvedAt = uint64(block.timestamp);
        d.unlockAt = uint64(block.timestamp) + appealWindow;

        // Slash first-panel resolvers who were drawn but never voted. Vote
        // direction is NOT punished at this stage; an appeal is the check on
        // a wrong decision, and only then is the first panel slashed (N-3).
        for (uint256 i = 0; i < d.memberCount; i++) {
            address member = d.members[i];
            if (!d.hasVoted[member]) {
                _slash(member, SLASH_BPS, 1);
            }
            _extendLock(member, d.unlockAt);
        }

        emit DisputeDecisionRecorded(disputeId, releaseToSeller, d.unlockAt);
    }

    /// @notice Settle the escrow with the first decision once the appeal window
    ///         has elapsed without an appeal. Permissionless.
    function finalize(uint256 disputeId) external nonReentrant {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Resolved) revert DisputeNotOpen();
        if (block.timestamp < d.unlockAt) revert AppealWindowActive();

        // State first (CEI): the dispute is Final before any payout or the
        // external vault call, so a re-entered call sees a closed dispute.
        d.state = DisputeState.Final;
        _payoutFirstRound(disputeId, d);
        vault.resolveDispute(d.escrowId, d.releaseToSeller);
        emit DisputeSettled(disputeId, d.escrowId, d.releaseToSeller);
    }

    /// @notice Appeal a first decision before the window closes. Either party
    ///         may appeal; the appellant posts a larger bond and a 5-resolver
    ///         panel is drawn. A 3-of-5 majority is final.
    function appeal(uint256 disputeId) external payable nonReentrant {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Resolved) revert DisputeNotOpen();
        if (block.timestamp >= d.unlockAt) revert AppealWindowClosed();

        SweeftVault.Escrow memory escrow = vault.getEscrow(d.escrowId);
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotParty();
        uint256 required = appealBondFor(escrow.amount);
        if (msg.value < required) revert BondTooLow();

        d.state = DisputeState.Appealed;
        d.appealSelected = true;
        d.appellant = msg.sender;
        d.appealBond = msg.value;
        d.appealVotingEndsAt = uint64(block.timestamp) + votingPeriod;

        uint8 chosen = _drawPanel(d, escrow, APPEAL_BOARD_SIZE, 2);
        if (chosen < APPEAL_BOARD_SIZE) revert PanelUnavailable();
        d.appealMemberCount = chosen;

        // Keep both panels' stake exposed while the appeal is decided.
        for (uint256 i = 0; i < d.memberCount; i++) {
            _extendLock(d.members[i], d.appealVotingEndsAt + appealWindow);
        }
        for (uint256 i = 0; i < chosen; i++) {
            _extendLock(d.appealMembers[i], d.appealVotingEndsAt + appealWindow);
        }

        emit AppealOpened(disputeId, d.escrowId, msg.sender, d.appealVotingEndsAt, msg.value);
        emit AppealPanelSelected(disputeId, d.appealMembers, chosen);
    }

    /// @notice Cast an appeal-panel vote. A 3-of-5 majority is final.
    function castAppealVote(uint256 disputeId, bool releaseToSeller) external nonReentrant {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Appealed) revert DisputeNotOpen();
        if (block.timestamp >= d.appealVotingEndsAt) revert VotingClosed();
        if (d.roundOf[msg.sender] != 2) revert NotMember();
        if (d.hasVoted[msg.sender]) revert AlreadyVoted();

        d.hasVoted[msg.sender] = true;
        d.votedRelease[msg.sender] = releaseToSeller;
        if (releaseToSeller) {
            d.appealVotesForRelease += 1;
        } else {
            d.appealVotesForRefund += 1;
        }
        emit AppealResolverVoted(disputeId, msg.sender, releaseToSeller);

        if (d.appealVotesForRelease >= 3) {
            _finalizeAppeal(disputeId, d, true);
        } else if (d.appealVotesForRefund >= 3) {
            _finalizeAppeal(disputeId, d, false);
        }
    }

    /// @notice If the appeal panel deadlocks, the first decision stands. The
    ///         appeal panel is still paid for voting; the appellant's remaining
    ///         bond goes to the treasury (indecisive appeal).
    function resolveAppealExpired(uint256 disputeId) external nonReentrant {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Appealed) revert DisputeNotOpen();
        if (block.timestamp < d.appealVotingEndsAt) revert VotingStillOpen();
        if (d.appealVotesForRelease >= 3 || d.appealVotesForRefund >= 3) revert NoMajority();

        _finalizeAppeal(disputeId, d, d.releaseToSeller);
    }

    function _finalizeAppeal(uint256 disputeId, Dispute storage d, bool finalOutcome) internal {
        bool overturned = finalOutcome != d.releaseToSeller;

        // Slash appeal-panel members who never voted.
        for (uint256 i = 0; i < d.appealMemberCount; i++) {
            address member = d.appealMembers[i];
            if (!d.hasVoted[member]) {
                _slash(member, SLASH_BPS, 2);
            }
            _extendLock(member, uint64(block.timestamp) + appealWindow);
        }

        // If the appeal overturns the first decision, slash the first-panel
        // voters who backed the wrong outcome (N-3).
        if (overturned) {
            for (uint256 i = 0; i < d.memberCount; i++) {
                address member = d.members[i];
                if (d.hasVoted[member] && d.votedRelease[member] == d.releaseToSeller) {
                    _slash(member, APPEAL_OVERTURN_SLASH_BPS, 1);
                }
            }
        }

        // State first (CEI): Final + the final outcome are recorded before
        // any payout or the external vault call.
        d.state = DisputeState.Final;
        d.releaseToSeller = finalOutcome;

        _payoutFirstRound(disputeId, d);

        // Appeal panel is paid from the appeal bond for either outcome.
        uint256 voters = uint256(d.appealVotesForRelease) + uint256(d.appealVotesForRefund);
        uint256 remainder = d.appealBond;
        if (voters > 0 && d.appealBond > 0) {
            uint256 fee = (d.appealBond * APPEAL_FEE_BPS) / 10_000;
            uint256 perVoter = fee / voters;
            d.appealRewardPerVoter = perVoter;
            rewardPool += perVoter * voters;
            emit RewardFunded(disputeId, perVoter * voters);
            remainder = d.appealBond - (perVoter * voters);
        } else {
            rewardPool += d.appealBond;
            remainder = 0;
        }
        d.appealBond = 0;

        if (remainder > 0) {
            // A successful appellant gets the unused bond back; a frivolous
            // (upheld) appeal forfeits it to the treasury.
            address payee = overturned ? d.appellant : treasury;
            if (!_send(payee, remainder)) {
                rewardPool += remainder; // never brick settlement
            }
        }

        vault.resolveDispute(d.escrowId, finalOutcome);
        emit AppealResolved(disputeId, finalOutcome, overturned);
        emit DisputeSettled(disputeId, d.escrowId, finalOutcome);
    }

    /// @dev Pay the first panel's fixed fee from the raiser bond and refund the
    ///      unused part. Safe to call once per dispute.
    function _payoutFirstRound(uint256 disputeId, Dispute storage d) internal {
        uint256 bond = d.bond;
        if (bond == 0) return;
        d.bond = 0;

        uint256 voters = uint256(d.votesForRelease) + uint256(d.votesForRefund);
        uint256 remainder = bond;
        if (voters > 0) {
            uint256 fee = (bond * RESOLVER_FEE_BPS) / 10_000;
            uint256 perVoter = fee / voters;
            d.rewardPerVoter = perVoter;
            rewardPool += perVoter * voters;
            emit RewardFunded(disputeId, perVoter * voters);
            remainder = bond - (perVoter * voters);
        } else {
            rewardPool += bond;
            remainder = 0;
        }

        if (remainder > 0) {
            if (!_send(d.raiser, remainder)) {
                rewardPool += remainder;
            }
        }
    }

    /// @notice Upper bound on panel-draw attempts per dispute, as a multiple
    ///         of the pool size (QC4-6: explicitly bounded loop).
    uint256 public constant MAX_DRAW_ATTEMPTS_PER_POOL = 6;

    function _drawPanel(
        Dispute storage d,
        SweeftVault.Escrow memory escrow,
        uint256 size,
        uint8 round
    ) internal returns (uint8 chosen) {
        uint256 required = minStakeFor(escrow.amount);
        uint256 n = resolverPool.length;
        if (n == 0) return 0;

        // Bounded for-loop: at most n * MAX_DRAW_ATTEMPTS_PER_POOL iterations,
        // whatever the pool contains (parties/verifier/carrier are skipped).
        uint256 maxAttempts = n * MAX_DRAW_ATTEMPTS_PER_POOL;
        for (uint256 attempts; attempts < maxAttempts && chosen < size; attempts++) {
            uint256 idx = uint256(
                keccak256(abi.encode(block.prevrandao, d.escrowId, round, chosen, attempts))
            ) % n;
            address cand = resolverPool[idx];

            if (d.roundOf[cand] != 0) continue; // already on a panel
            if (stakeOf[cand] < required) continue;
            if (cand == escrow.buyer || cand == escrow.seller) continue;
            if (escrow.verifier != address(0) && cand == escrow.verifier) continue;
            if (escrow.logisticsPartner != address(0) && cand == escrow.logisticsPartner) continue;

            d.roundOf[cand] = round;
            d.hasVoted[cand] = false;
            if (round == 1) {
                d.members[chosen] = cand;
            } else {
                d.appealMembers[chosen] = cand;
            }
            chosen++;
            // Cover the panel through voting plus the appeal window.
            _extendLock(cand, uint64(block.timestamp) + votingPeriod + appealWindow);
        }
    }

    function _slash(address member, uint256 bps, uint8 round) internal {
        uint256 stake = stakeOf[member];
        if (stake == 0) return;
        uint256 slash = (stake * bps) / 10_000;
        if (slash == 0) return;
        stakeOf[member] = stake - slash;
        rewardPool += slash;
        emit Slashed(member, slash, round);
    }

    function _extendLock(address member, uint64 until) internal {
        if (until > lockedUntil[member]) {
            lockedUntil[member] = until;
        }
    }

    function _send(address to, uint256 amount) internal returns (bool) {
        if (to == address(0) || amount == 0) return false;
        (bool ok,) = payable(to).call{ value: amount }("");
        return ok;
    }

    // ------------------------------------------------------------------
    // Rewards
    // ------------------------------------------------------------------

    /// @notice Fixed reward for a resolver that voted, per panel round.
    function resolverReward(uint256 disputeId, address member) public view returns (uint256) {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Final || !d.hasVoted[member]) return 0;
        return d.roundOf[member] == 2 ? d.appealRewardPerVoter : d.rewardPerVoter;
    }

    function claimReward(uint256 disputeId) external nonReentrant {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Final) revert NotFinal();
        if (!d.hasVoted[msg.sender]) revert NotMember();
        if (d.claimed[msg.sender]) revert AlreadyVoted();

        uint8 round = d.roundOf[msg.sender];
        uint256 reward = round == 2 ? d.appealRewardPerVoter : d.rewardPerVoter;
        if (reward == 0) revert NoStake();
        if (rewardPool < reward) revert TransferFailed();

        d.claimed[msg.sender] = true;
        rewardPool -= reward;
        if (!_send(msg.sender, reward)) revert TransferFailed();
        emit RewardClaimed(disputeId, msg.sender, reward, round);
    }

    /// @notice Move stranded reward-pool funds to the treasury (N-4).
    function sweep() external onlyOwner nonReentrant {
        uint256 amount = rewardPool;
        if (amount == 0) revert ZeroAmount();
        rewardPool = 0;
        if (!_send(treasury, amount)) revert TransferFailed();
        emit Swept(treasury, amount);
    }

    /// @notice Pull a credit the Vault accrued for the board on a failed fee
    ///         push (N-4). The Vault sends the withdrawal to the caller.
    function withdrawVaultCredits() external nonReentrant {
        uint256 amount = vault.credits(address(this));
        if (amount == 0) revert ZeroAmount();
        vault.withdrawCredits();
        emit Swept(address(this), amount);
    }

    receive() external payable {}

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
            uint64 joinEndsAt,
            uint64 votingEndsAt,
            uint64 unlockAt,
            DisputeState state,
            bool panelSelected,
            bool releaseToSeller,
            uint8 votesForRelease,
            uint8 votesForRefund,
            uint8 memberCount,
            uint256 bond,
            uint256 rewardPerVoter,
            address[3] memory members
        )
    {
        Dispute storage d = disputes[disputeId];
        return (
            d.escrowId,
            d.raiser,
            d.openedAt,
            d.joinEndsAt,
            d.votingEndsAt,
            d.unlockAt,
            d.state,
            d.panelSelected,
            d.releaseToSeller,
            d.votesForRelease,
            d.votesForRefund,
            d.memberCount,
            d.bond,
            d.rewardPerVoter,
            d.members
        );
    }

    function appealInfo(uint256 disputeId)
        external
        view
        returns (
            bool appealSelected,
            bool appealReleaseToSeller,
            uint8 appealVotesForRelease,
            uint8 appealVotesForRefund,
            uint8 appealMemberCount,
            uint256 appealBond,
            uint256 appealRewardPerVoter,
            uint64 appealVotingEndsAt,
            address[5] memory appealMembers
        )
    {
        Dispute storage d = disputes[disputeId];
        return (
            d.appealSelected,
            d.releaseToSeller,
            d.appealVotesForRelease,
            d.appealVotesForRefund,
            d.appealMemberCount,
            d.appealBond,
            d.appealRewardPerVoter,
            d.appealVotingEndsAt,
            d.appealMembers
        );
    }

    function hasVoted(uint256 disputeId, address member) external view returns (bool) {
        return disputes[disputeId].hasVoted[member];
    }

    function memberCount(uint256 disputeId) external view returns (uint8) {
        return disputes[disputeId].memberCount;
    }

    function members(uint256 disputeId) external view returns (address[3] memory) {
        return disputes[disputeId].members;
    }

    function appealMembers(uint256 disputeId) external view returns (address[5] memory) {
        return disputes[disputeId].appealMembers;
    }

    function memberRound(uint256 disputeId, address member) external view returns (uint8) {
        return disputes[disputeId].roundOf[member];
    }

    function poolSize() external view returns (uint256) {
        return resolverPool.length;
    }
}
