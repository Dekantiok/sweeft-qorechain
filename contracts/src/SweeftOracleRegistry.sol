// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SweeftOracleRegistry — authorized fulfilment verifiers
/// @notice Records who may attest fulfilment for escrows, and the M-of-N
///         threshold the Vault requires before an escrow counts as attested.
///         Ownership is intended to be transferred to the SweeftDAO after
///         deployment, so verifier approval (and the threshold) is governed
///         rather than hardcoded. A single verifier can never, alone, block a
///         buyer's refund path once the threshold is greater than one.
contract SweeftOracleRegistry {
    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event VerifierAdded(address indexed verifier);
    event VerifierRemoved(address indexed verifier);
    event ThresholdUpdated(uint8 previousThreshold, uint8 newThreshold);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error NotOwner();
    error ZeroAddress();
    error AlreadyVerifier();
    error NotVerifier();
    error InvalidThreshold();

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    address public owner;
    mapping(address => bool) public isVerifier;
    uint256 public verifierCount;

    /// @notice Number of distinct verifier attestations the Vault requires
    ///         before an escrow is considered attested. Defaults to 1 for
    ///         single-oracle testnet operation; raise to 2-of-3 for production.
    uint8 public threshold = 1;

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
        verifierCount += 1;
        emit VerifierAdded(verifier);
    }

    function removeVerifier(address verifier) external onlyOwner {
        if (!isVerifier[verifier]) revert NotVerifier();

        isVerifier[verifier] = false;
        verifierCount -= 1;
        emit VerifierRemoved(verifier);
    }

    /// @notice Set the M-of-N attestation threshold. Capped at the number of
    ///         registered verifiers so an unreachable threshold cannot lock
    ///         escrows; always at least 1 when a verifier exists.
    function setThreshold(uint8 newThreshold) external onlyOwner {
        if (newThreshold == 0) revert InvalidThreshold();
        if (newThreshold > verifierCount) revert InvalidThreshold();
        emit ThresholdUpdated(threshold, newThreshold);
        threshold = newThreshold;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();

        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
