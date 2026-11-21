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
        uint256 amount;
        uint64 deliveryDeadline; // unix seconds
        uint64 createdAt; // unix seconds
        EscrowStatus status;
        bool delivered; // seller marked delivered or buyer confirmed receipt
        bool fulfilledConfirmed; // buyer confirmed receipt (full release path)
        bool evidenceAttested; // oracle verifier attested fulfilment
        bool released;
        address verifier; // the verifier that attested (if any)
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
    ///      treasury (70%) and the dispute reward pool (30%).
    function _payRelease(uint256 escrowId, Escrow storage e) internal {
        uint256 fee = _feeFor(e.amount);
        uint256 sellerAmount = e.amount - fee;

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
