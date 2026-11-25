// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SweeftOracleRegistry — authorized fulfilment verifiers
/// @notice Records who may attest fulfilment for escrows, the M-of-N threshold
///         the Vault requires, and a per-verifier bond the DAO can slash for a
///         provably false attestation (N-9). Ownership transfers to the DAO
///         after deployment.
contract SweeftOracleRegistry {
    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event VerifierAdded(address indexed verifier);
    event VerifierRemoved(address indexed verifier);
    event ThresholdUpdated(uint8 previousThreshold, uint8 newThreshold);
    event VerifierStaked(address indexed verifier, uint256 amount, uint256 total);
    event VerifierSlashed(address indexed verifier, address indexed to, uint256 amount);
    event MinVerifierStakeUpdated(uint256 previousStake, uint256 newStake);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error NotOwner();
    error ZeroAddress();
    error AlreadyVerifier();
    error NotVerifier();
    error InvalidThreshold();
    error ThresholdUnreachable();
    error StakeTooLow();
    error StakeLocked();
    error TransferFailed();

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    address public owner;
    mapping(address => bool) public isVerifier;
    uint256 public verifierCount;

    /// @notice Distinct verifier attestations the Vault requires before an
    ///         escrow counts as attested. Defaults to 1 for single-oracle
    ///         testnet operation; raise to 2-of-3 for production.
    uint8 public threshold = 1;

    /// @notice Bond a verifier must hold to be approved. 0 disables the bond
    ///         (testnet default); raise it before real value is at stake.
    uint256 public minVerifierStake = 0;
    mapping(address => uint256) public verifierStake;

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ------------------------------------------------------------------
    // Verifier actions
    // ------------------------------------------------------------------

    function stake() external payable {
        if (msg.value == 0) revert StakeTooLow();
        verifierStake[msg.sender] += msg.value;
        emit VerifierStaked(msg.sender, msg.value, verifierStake[msg.sender]);
    }

    /// @notice Withdraw a verifier bond. Blocked while still an approved
    ///         verifier, so a verifier cannot attest then walk away unstaked.
    function withdrawStake() external {
        if (isVerifier[msg.sender]) revert StakeLocked();
        uint256 amount = verifierStake[msg.sender];
        if (amount == 0) revert StakeTooLow();
        verifierStake[msg.sender] = 0;
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert TransferFailed();
    }

    // ------------------------------------------------------------------
    // Owner actions
    // ------------------------------------------------------------------

    function addVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) revert ZeroAddress();
        if (isVerifier[verifier]) revert AlreadyVerifier();
        if (verifierStake[verifier] < minVerifierStake) revert StakeTooLow();

        isVerifier[verifier] = true;
        verifierCount += 1;
        emit VerifierAdded(verifier);
    }

    /// @notice Remove a verifier. Blocked if it would make the threshold
    ///         unreachable (N-9).
    function removeVerifier(address verifier) external onlyOwner {
        if (!isVerifier[verifier]) revert NotVerifier();
        if (verifierCount - 1 < threshold) revert ThresholdUnreachable();

        isVerifier[verifier] = false;
        verifierCount -= 1;
        emit VerifierRemoved(verifier);
    }

    /// @notice Slash a verifier's bond for a provably false attestation,
    ///         sending it to `to` (e.g. the harmed party or treasury).
    function slashVerifier(address verifier, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = verifierStake[verifier];
        if (amount == 0) revert StakeTooLow();
        verifierStake[verifier] = 0;
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit VerifierSlashed(verifier, to, amount);
    }

    /// @notice Set the M-of-N attestation threshold. Capped at the number of
    ///         registered verifiers so an unreachable threshold cannot lock
    ///         escrows; always at least 1.
    function setThreshold(uint8 newThreshold) external onlyOwner {
        if (newThreshold == 0) revert InvalidThreshold();
        if (newThreshold > verifierCount) revert InvalidThreshold();
        emit ThresholdUpdated(threshold, newThreshold);
        threshold = newThreshold;
    }

    function setMinVerifierStake(uint256 newMinStake) external onlyOwner {
        emit MinVerifierStakeUpdated(minVerifierStake, newMinStake);
        minVerifierStake = newMinStake;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
