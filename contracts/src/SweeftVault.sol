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
        Refunded
    }

    struct Escrow {
        address buyer;
        address seller;
        uint256 amount;
        uint64 deliveryDeadline; // unix seconds
        uint64 createdAt; // unix seconds
        EscrowStatus status;
        bool delivered; // seller marked delivered or buyer confirmed receipt
        bool fulfilledConfirmed; // buyer confirmed receipt (full release path)
        bool evidenceAttested; // oracle verifier attested fulfilment
        bool released;
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

    /// @notice Contract deployment time, used to separate refund nonces.
    uint256 public immutable deployedAt;

    uint256 public escrowCount;
    mapping(uint256 => Escrow) public escrows;

    /// @notice Per-buyer PQ nonce: prevents replay of a release/refund signature.
    mapping(address => uint256) public pqcNonce;

    constructor(address _oracleRegistry) {
        if (_oracleRegistry == address(0)) revert InvalidParties();
        oracleRegistry = _oracleRegistry;
        deployedAt = block.timestamp;
    }

    // ------------------------------------------------------------------
    // Escrow lifecycle
    // ------------------------------------------------------------------

    /// @notice Create an escrow. Anyone may create one on behalf of buyer/seller.
    function createEscrow(address seller, uint64 deliveryDeadline, uint256 amount) external returns (uint256 escrowId) {
        if (seller == address(0) || seller == msg.sender) revert InvalidParties();
        if (amount == 0) revert InvalidAmount();

        escrowId = escrowCount;
        escrowCount = escrowId + 1;

        Escrow storage e = escrows[escrowId];
        e.buyer = msg.sender;
        e.seller = seller;
        e.amount = amount;
        e.deliveryDeadline = deliveryDeadline;
        e.createdAt = uint64(block.timestamp);

        emit EscrowCreated(escrowId, msg.sender, seller, amount, deliveryDeadline);
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
        emit EvidenceAttested(escrowId, msg.sender, evidenceHash);
    }

    /// @notice Release escrowed funds to the seller.
    /// @dev Eligible when the buyer confirmed receipt, or the escrow has been
    ///      delivered/attested and the delivery deadline has passed (inspection
    ///      window satisfied). Authorization is the buyer's registered
    ///      ML-DSA-87 signature over the release message; anyone may submit it.
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

        (bool ok,) = e.seller.call{ value: e.amount }("");
        if (!ok) revert TransferFailed();
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
        return abi.encode(
            "sweeft-release-v1", block.chainid, address(this), escrowId, buyer, recipient, amount, nonce
        );
    }

    function _refundMessage(uint256 escrowId, address buyer, address recipient, uint256 amount, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            "sweeft-refund-v1", block.chainid, address(this), escrowId, buyer, recipient, amount, nonce
        );
    }

    /// @dev Reads the guardian's registered ML-DSA-87 key from the chain and
    ///      verifies the signature against the exact message. Fails closed.
    function _requirePqcSignature(address guardian, bytes memory message, bytes calldata signature) internal view {
        (bool registered,, bytes memory pubkey, bool proven) = PQC_KEYS.pqcKeyStatus(guardian);
        if (!registered || pubkey.length == 0) revert GuardianKeyNotRegistered();
        if (!proven) revert GuardianKeyNotProven();

        if (!PQC_VERIFY.pqcVerify(pubkey, signature, message)) revert BadPqcSignature();
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
