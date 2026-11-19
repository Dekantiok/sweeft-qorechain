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
