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
///                     markDelivered/confirmReceipt   (verifier threshold /
///                                        |            carrier attestation)
///                                        v
///                                  release (PQ-gated)
///
///      Refund path: if no verifier attestation and no delivery by
///      deliveryDeadline, the buyer can refund (also PQ-gated) after the
///      deadline, or cancel (classical) before funding.
///
///      Security notes (v5 hardening pass):
///        - delivery deadlines are bounded (MIN_WINDOW..MAX_WINDOW)
///        - buyer must have a registered, proven ML-DSA key at creation
///        - fee/treasury are snapshotted per escrow at creation
///        - carrier attestation is bound to (escrow, carrier, status, nonce)
///        - verifier attestation requires a registry threshold (M-of-N)
///        - payouts are push-with-credit-fallback and guarded against reentrancy
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
        bool evidenceAttested; // oracle/carrier threshold met
        bool released;
        address verifier; // the verifier/carrier that pushed attestation over threshold
        // --- logistics (v4, appended for ABI compatibility) ---
        address logisticsPartner; // zero = physical-less / digital default
        uint256 logisticsAmount; // paid to partner, separate from seller goods
        bool carrierAttested; // signed carrier payload verified on-chain
        uint64 carrierAttestedAt;
        bytes32 carrierPayloadHash; // keccak256(canonical tracking payload)
        address carrierSigner;
        // --- v5 appended fields ---
        uint256 feeBpsSnapshot; // platform fee captured at creation
        address treasurySnapshot; // treasury captured at creation
        string carrierStatus; // last carrier status (e.g. DELIVERED, LOST)
        uint64 carrierIssuedAt; // carrier-claimed issue time (ms or s, opaque)
        uint8 verifierAttestations; // distinct verifier attestations recorded
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
    event VerifierThresholdReached(uint256 indexed escrowId, uint8 attestations);
    event FundsReleased(uint256 indexed escrowId, address indexed seller, uint256 amount, uint256 nonce);
    event EscrowCancelled(uint256 indexed escrowId);
    event EscrowRefunded(uint256 indexed escrowId, address indexed buyer, uint256 amount, uint256 nonce);
    event DisputeRaised(uint256 indexed escrowId, address indexed raisedBy);
    event DisputeResolved(uint256 indexed escrowId, bool releaseToSeller, uint256 fee);
    event FeeCollected(uint256 indexed escrowId, uint256 treasuryShare, uint256 disputeShare);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event FeeUpdated(uint256 previousFeeBps, uint256 newFeeBps);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event CarrierRegistered(address indexed carrier, string providerId);
    event CarrierRemoved(address indexed carrier);
    event CarrierAttested(uint256 indexed escrowId, address indexed carrier, bytes32 payloadHash, string status, string trackingNumber);
    event LogisticsPaid(uint256 indexed escrowId, address indexed partner, uint256 amount);
    event LogisticsHeld(uint256 indexed escrowId, address indexed buyer, uint256 amount);
    event CreditsWithdrawn(address indexed account, uint256 amount);

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
    error NotDeployer();
    error NotDisputeBoard();
    error FeeTooHigh();
    error NotDisputable();
    error NotCarrier();
    error BadCarrierSignature();
    error CarrierKeyNotRegistered();
    error CarrierKeyNotProven();
    error BadPayloadHash();
    error BadTimestamp();
    error StaleAttestation();
    error AlreadyWired();

    // ------------------------------------------------------------------
    // QoreChain PQC precompiles (testnet-only; addresses must be lowercase)
    // ------------------------------------------------------------------

    IPQCVerify internal constant PQC_VERIFY = IPQCVerify(0x0000000000000000000000000000000000000a01);
    IPQCKeyStatus internal constant PQC_KEYS = IPQCKeyStatus(0x0000000000000000000000000000000000000a02);

    // ------------------------------------------------------------------
    // Immutables / storage
    // ------------------------------------------------------------------

    /// @notice Registry that authorizes oracle verifiers and sets the threshold.
    address public immutable oracleRegistry;

    /// @notice Deployer, allowed to wire the Marketplace/Board once.
    address public immutable deployer;

    /// @notice The Marketplace, allowed to create escrows on behalf of buyers.
    address public marketplace;

    /// @notice Cosmos chain id used in QoreSign message domain separation.
    string public cosmosChainId;

    /// @notice Contract owner (deployer, then the DAO). Governs fee parameters.
    address public owner;

    /// @notice Platform fee on successful release, in basis points (200 = 2%).
    uint256 public feeBps;

    /// @notice Receives the treasury share (70%) of platform fees.
    address public treasury;

    /// @notice The dispute board; receives the resolver share (30%) of fees.
    address public disputeBoard;

    uint256 public constant TREASURY_SHARE_BPS = 7000;
    uint256 public constant DISPUTE_SHARE_BPS = 3000;
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice Delivery-window bounds enforced at escrow creation.
    uint64 public constant MIN_WINDOW = 1 days;
    uint64 public constant MAX_WINDOW = 90 days;

    /// @notice A carrier payload may be at most this old when attested.
    uint64 public constant MAX_ATTEST_AGE = 7 days;

    uint256 public immutable deployedAt;

    uint256 public escrowCount;
    mapping(uint256 => Escrow) public escrows;

    /// @notice Per-escrow nonce: prevents replay of a release/refund signature.
    ///         Keying by escrow (not buyer) keeps parallel escrows independent,
    ///         so settling one escrow cannot invalidate another's signature.
    mapping(uint256 => uint256) public escrowNonce;

    /// @notice Authorized logistics carriers, by QoreChain account address.
    mapping(address => bool) public isCarrier;
    mapping(address => string) public carrierProviderId;
    /// @notice Per-carrier nonce to make carrier attestations single-use.
    mapping(address => uint256) public carrierNonce;

    /// @notice Distinct verifier attestations per escrow (M-of-N threshold).
    mapping(uint256 => mapping(address => bool)) public verifierAttested;
    mapping(uint256 => uint8) public verifierAttestCount;

    /// @notice Push-payment fallback: recipients that reject a transfer accrue
    ///         a credit they can withdraw later, so settlement never bricks.
    mapping(address => uint256) public credits;

    /// @dev Reentrancy guard (self-contained; no external dependency).
    uint256 private _lock = 1;

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

    modifier nonReentrant() {
        if (_lock != 1) revert InvalidStatus();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @notice Update the platform fee (DAO-governed). Applies to escrows
    ///         created after this call; funded escrows keep their snapshot.
    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    /// @notice Update the treasury address (DAO-governed). Funded escrows keep
    ///         their snapshot, so this cannot redirect an in-flight fee.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidParties();
        emit TreasuryUpdated(treasury, newTreasury);
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
        if (msg.sender != deployer) revert NotDeployer();
        if (disputeBoard != address(0)) revert AlreadyWired();
        if (board == address(0)) revert InvalidParties();
        disputeBoard = board;
    }

    /// @notice Wire the Marketplace contract. Callable once by the deployer.
    function setMarketplace(address marketplaceAddress) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (marketplace != address(0)) revert AlreadyWired();
        if (marketplaceAddress == address(0)) revert InvalidParties();
        marketplace = marketplaceAddress;
    }

    /// @notice Register a logistics carrier (owner/DAO only).
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
    function createEscrow(address buyer, address seller, uint64 deliveryDeadline, uint256 amount)
        external
        payable
        returns (uint256 escrowId)
    {
        if (buyer == address(0) || seller == address(0) || seller == buyer) revert InvalidParties();
        if (amount == 0) revert InvalidAmount();
        if (msg.sender != buyer && msg.sender != marketplace) revert NotBuyer();
        if (msg.value != 0 && msg.value != amount) revert WrongDeposit();
        _validateDeadline(deliveryDeadline);
        _requireRegisteredKey(buyer);

        escrowId = escrowCount;
        escrowCount = escrowId + 1;

        Escrow storage e = escrows[escrowId];
        e.buyer = buyer;
        e.seller = seller;
        e.amount = amount;
        e.deliveryDeadline = deliveryDeadline;
        e.createdAt = uint64(block.timestamp);
        e.feeBpsSnapshot = feeBps;
        e.treasurySnapshot = treasury;

        emit EscrowCreated(escrowId, buyer, seller, amount, deliveryDeadline);

        if (msg.value == amount) {
            e.status = EscrowStatus.Funded;
            emit EscrowFunded(escrowId, buyer, msg.value);
        }
    }

    /// @notice Create an escrow with a logistics allocation.
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
        _validateDeadline(deliveryDeadline);
        _requireRegisteredKey(buyer);

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
        e.feeBpsSnapshot = feeBps;
        e.treasurySnapshot = treasury;

        emit EscrowCreated(escrowId, buyer, seller, amount, deliveryDeadline);

        if (msg.value == amount) {
            e.status = EscrowStatus.Funded;
            emit EscrowFunded(escrowId, buyer, msg.value);
        }
    }

    function fundEscrow(uint256 escrowId) external payable {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert InvalidEscrow();
        if (e.status != EscrowStatus.None) revert InvalidStatus();
        if (msg.sender != e.buyer) revert NotBuyer();
        if (msg.value != e.amount) revert WrongDeposit();

        e.status = EscrowStatus.Funded;
        emit EscrowFunded(escrowId, e.buyer, msg.value);
    }

    function markFulfilled(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) revert InvalidStatus();
        if (msg.sender != e.seller) revert NotSeller();
        emit MarkedFulfilled(escrowId, e.seller);
    }

    function markDelivered(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) revert InvalidStatus();
        if (msg.sender != e.seller) revert NotSeller();
        e.delivered = true;
        emit MarkedDelivered(escrowId, e.seller);
    }

    function confirmReceipt(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) revert InvalidStatus();
        if (msg.sender != e.buyer) revert NotBuyer();
        e.fulfilledConfirmed = true;
        emit ReceiptConfirmed(escrowId, e.buyer);
    }

    /// @notice Authorized verifier records a fulfilment attestation. The escrow
    ///         only becomes `evidenceAttested` once the registry threshold is
    ///         met (M-of-N), so one rogue or compromised verifier cannot on its
    ///         own block the buyer's refund path.
    function attestEvidence(uint256 escrowId, bytes32 evidenceHash) external {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert InvalidEscrow();
        if (e.status != EscrowStatus.Funded) revert InvalidStatus();
        if (!_isVerifier(msg.sender)) revert NotVerifier();

        if (!verifierAttested[escrowId][msg.sender]) {
            verifierAttested[escrowId][msg.sender] = true;
            uint8 count = e.verifierAttestations + 1;
            e.verifierAttestations = count;
            verifierAttestCount[escrowId] = count;
            emit EvidenceAttested(escrowId, msg.sender, evidenceHash);

            if (count >= _verifierThreshold()) {
                e.evidenceAttested = true;
                e.verifier = msg.sender;
                emit VerifierThresholdReached(escrowId, count);
            }
        }
    }

    /// @notice Verify the carrier's ML-DSA-87 signature over a canonical
    ///         tracking payload built on-chain, binding the attestation to this
    ///         escrow, carrier, status and a single-use nonce. Only a
    ///         `DELIVERED` status counts as fulfilment; any other status is
    ///         recorded but leaves the buyer's refund path open.
    function attestCarrierEvidence(
        uint256 escrowId,
        string calldata trackingNumber,
        string calldata status,
        uint64 issuedAt,
        bytes calldata signature
    ) external {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert InvalidEscrow();
        if (e.status != EscrowStatus.Funded) revert InvalidStatus();
        // Only the escrow's assigned logistics partner may attest for it.
        if (e.logisticsPartner == address(0) || msg.sender != e.logisticsPartner) revert NotCarrier();
        if (issuedAt > block.timestamp) revert BadTimestamp();
        if (block.timestamp - issuedAt > MAX_ATTEST_AGE) revert StaleAttestation();

        uint256 nonce = carrierNonce[msg.sender];
        bytes memory message = _carrierMessage(msg.sender, escrowId, trackingNumber, status, issuedAt, nonce);
        _requireCarrierSignature(msg.sender, message, signature);
        carrierNonce[msg.sender] = nonce + 1;

        bool deliveredStatus = keccak256(bytes(status)) == keccak256(bytes("DELIVERED"));

        e.carrierAttested = true;
        e.carrierAttestedAt = uint64(block.timestamp);
        e.carrierPayloadHash = keccak256(message);
        e.carrierSigner = msg.sender;
        e.carrierStatus = status;
        e.carrierIssuedAt = issuedAt;

        if (deliveredStatus) {
            e.delivered = true;
            e.evidenceAttested = true;
            e.verifier = msg.sender; // excluded from dispute board like a verifier
        }

        emit CarrierAttested(escrowId, msg.sender, e.carrierPayloadHash, status, trackingNumber);
    }

    /// @notice Release escrowed funds to the seller, charging the platform fee.
    function release(uint256 escrowId, bytes calldata signature) external nonReentrant {
        if (!isReleaseEligible(escrowId)) revert NotReleaseEligible();

        Escrow storage e = escrows[escrowId];
        uint256 nonce = escrowNonce[escrowId];
        bytes memory message = _releaseMessage(escrowId, e.buyer, e.seller, e.amount, nonce);
        _requirePqcSignature(e.buyer, message, signature);

        escrowNonce[escrowId] = nonce + 1;
        e.released = true;
        e.status = EscrowStatus.Completed;

        emit FundsReleased(escrowId, e.seller, e.amount, nonce);

        _payRelease(escrowId, e);
    }

    /// @notice Refund the buyer when the seller never delivered and no verifier
    ///         or carrier confirmed fulfilment.
    function refundAfterDeadline(uint256 escrowId, bytes calldata signature) external nonReentrant {
        if (!isRefundable(escrowId)) revert NotRefundable();

        Escrow storage e = escrows[escrowId];
        uint256 nonce = escrowNonce[escrowId];
        bytes memory message = _refundMessage(escrowId, e.buyer, e.buyer, e.amount, nonce);
        _requirePqcSignature(e.buyer, message, signature);

        escrowNonce[escrowId] = nonce + 1;
        e.status = EscrowStatus.Refunded;

        emit EscrowRefunded(escrowId, e.buyer, e.amount, nonce);

        _pay(e.buyer, e.amount);
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

    /// @notice Withdraw a credit accrued from a rejected push payment.
    function withdrawCredits() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert InvalidAmount();
        credits[msg.sender] = 0;
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit CreditsWithdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Disputes
    // ------------------------------------------------------------------

    /// @notice Freeze a funded escrow for dispute resolution.
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
    function resolveDispute(uint256 escrowId, bool releaseToSeller) external nonReentrant {
        if (msg.sender != disputeBoard) revert NotDisputeBoard();

        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Disputed) revert InvalidStatus();

        uint256 fee = 0;
        if (releaseToSeller) {
            e.released = true;
            e.status = EscrowStatus.Completed;
            fee = _feeForAmount(e.amount - e.logisticsAmount, e.feeBpsSnapshot);
            _payRelease(escrowId, e);
        } else {
            e.status = EscrowStatus.Refunded;
            _pay(e.buyer, e.amount);
        }

        emit DisputeResolved(escrowId, releaseToSeller, fee);
    }

    /// @dev Fee snapshot for a specific escrow (used by the dispute board).
    function escrowFeeBps(uint256 escrowId) external view returns (uint256) {
        return escrows[escrowId].feeBpsSnapshot;
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
        // Once fulfilment is claimed (seller delivery mark, verifier threshold
        // or a carrier DELIVERED attestation), the buyer cannot unilaterally
        // refund — disagreement must go through the dispute board.
        if (e.evidenceAttested || e.delivered) return false;
        return block.timestamp >= e.deliveryDeadline;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _validateDeadline(uint64 deliveryDeadline) internal view {
        uint64 nowTs = uint64(block.timestamp);
        if (deliveryDeadline < nowTs + MIN_WINDOW) revert InvalidDeadline();
        if (deliveryDeadline > nowTs + MAX_WINDOW) revert InvalidDeadline();
    }

    function _requireRegisteredKey(address account) internal view {
        (bool registered,, bytes memory pubkey, bool proven) = PQC_KEYS.pqcKeyStatus(account);
        if (!registered || pubkey.length == 0) revert GuardianKeyNotRegistered();
        if (!proven) revert GuardianKeyNotProven();
    }

    function _feeForAmount(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps) / 10_000;
    }

    /// @dev Push a payment; if the recipient rejects it, accrue a credit so the
    ///      escrow can still settle.
    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) {
            credits[to] += amount;
        }
    }

    function _payRelease(uint256 escrowId, Escrow storage e) internal {
        uint256 goodsAmount = e.amount - e.logisticsAmount;

        if (e.logisticsAmount > 0 && e.logisticsPartner != address(0)) {
            // The carrier is paid only when it attested delivery for this
            // escrow; otherwise the logistics share is held for the buyer.
            if (e.carrierAttested && e.delivered) {
                _pay(e.logisticsPartner, e.logisticsAmount);
                emit LogisticsPaid(escrowId, e.logisticsPartner, e.logisticsAmount);
            } else {
                credits[e.buyer] += e.logisticsAmount;
                emit LogisticsHeld(escrowId, e.buyer, e.logisticsAmount);
            }
        }

        uint256 fee = _feeForAmount(goodsAmount, e.feeBpsSnapshot);
        uint256 sellerAmount = goodsAmount - fee;

        if (fee > 0) {
            uint256 treasuryShare = (fee * TREASURY_SHARE_BPS) / 10_000;
            uint256 disputeShare = fee - treasuryShare;

            if (disputeBoard == address(0)) {
                treasuryShare = fee;
                disputeShare = 0;
            }

            _pay(e.treasurySnapshot, treasuryShare);

            if (disputeShare > 0) {
                (bool dOk,) = disputeBoard.call{ value: disputeShare }(
                    abi.encodeWithSignature("receiveFeeShare()")
                );
                if (!dOk) {
                    credits[disputeBoard] += disputeShare;
                }
            }

            emit FeeCollected(escrowId, treasuryShare, disputeShare);
        }

        _pay(e.seller, sellerAmount);
    }

    function _isVerifier(address account) internal view returns (bool) {
        (bool ok, bytes memory data) = oracleRegistry.staticcall(
            abi.encodeWithSignature("isVerifier(address)", account)
        );
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (bool));
    }

    function _verifierThreshold() internal view returns (uint8) {
        (bool ok, bytes memory data) = oracleRegistry.staticcall(
            abi.encodeWithSignature("threshold()")
        );
        if (!ok || data.length < 32) return 1;
        uint8 t = abi.decode(data, (uint8));
        return t == 0 ? 1 : t;
    }

    function _requireCarrierSignature(address carrier, bytes memory message, bytes calldata signature) internal view {
        (bool registered,, bytes memory pubkey, bool proven) = PQC_KEYS.pqcKeyStatus(carrier);
        if (!registered || pubkey.length == 0) revert CarrierKeyNotRegistered();
        if (!proven) revert CarrierKeyNotProven();
        if (!PQC_VERIFY.pqcVerify(pubkey, signature, message)) revert BadCarrierSignature();
    }

    function _carrierMessage(
        address carrier,
        uint256 escrowId,
        string memory trackingNumber,
        string memory status,
        uint64 issuedAt,
        uint256 nonce
    ) internal view returns (bytes memory) {
        return bytes(
            string.concat(
                "sweeft-carrier-v1|provider=",
                carrierProviderId[carrier],
                "|tracking=",
                trackingNumber,
                "|escrow=",
                _uintToString(escrowId),
                "|status=",
                status,
                "|issued=",
                _uintToString(uint256(issuedAt)),
                "|nonce=",
                _uintToString(nonce)
            )
        );
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

    function _requirePqcSignature(address guardian, bytes memory message, bytes calldata signature) internal view {
        (bool registered,, bytes memory pubkey, bool proven) = PQC_KEYS.pqcKeyStatus(guardian);
        if (!registered || pubkey.length == 0) revert GuardianKeyNotRegistered();
        if (!proven) revert GuardianKeyNotProven();

        bytes memory payload = abi.encodePacked("qorechain-msg-v1|", cosmosChainId, "|", message);
        if (!PQC_VERIFY.pqcVerify(pubkey, signature, payload)) revert BadPqcSignature();
    }

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
    function pqcVerify(bytes calldata pubkey, bytes calldata signature, bytes calldata message)
        external
        view
        returns (bool);
}

interface IPQCKeyStatus {
    function pqcKeyStatus(address account)
        external
        view
        returns (bool registered, uint8 algorithmId, bytes memory pubkey, bool proven);
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
        uint256 price; // total (goods + logistics) for a purchase
        uint64 quantity;
        ListingStatus status;
        string metadataUri;
        bytes32 metadataHash; // sha256 of the metadata JSON
        uint64 createdAt;
        uint64 updatedAt;
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
    error PriceAboveMax();
    error MetadataMismatch();

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
        // A price below the logistics fee would make the listing unbuyable.
        if (listing.logisticsFee > price) revert InvalidPrice();

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

    /// @notice Buy a listing, pinning the terms the buyer reviewed: the exact
    ///         payment (`maxPrice`) and the metadata hash. If the seller has
    ///         changed either since review, the purchase reverts.
    /// @param listingId the listing to buy
    /// @param deliveryDeadline unix seconds; must satisfy the vault's window
    /// @param maxPrice the most the buyer will pay (usually the quoted price)
    /// @param expectedMetadataHash the metadata hash the buyer reviewed
    function purchase(
        uint256 listingId,
        uint64 deliveryDeadline,
        uint256 maxPrice,
        bytes32 expectedMetadataHash
    ) external payable returns (uint256 escrowId) {
        Listing storage listing = listings[listingId];
        if (listing.status != ListingStatus.Active) revert ListingNotActive();
        if (listing.quantity == 0) revert OutOfStock();
        if (listing.price > maxPrice) revert PriceAboveMax();
        if (listing.metadataHash != expectedMetadataHash) revert MetadataMismatch();
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

// ============ SweeftDisputeBoard.sol ============
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

// ============ SweeftDAO2.sol ============
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SweeftDAO2 — proposal registry and one-wallet-one-vote governance
/// @notice Governs Sweeft application parameters. Executed proposals call
///         allowlisted (target, selector) pairs only: the oracle registry
///         (verifier approval, threshold), the vault (fee, treasury) and the
///         dispute board (stake, voting parameters).
///
///         Hardening (v5):
///           - voting periods are bounded (MIN_VOTING_PERIOD..MAX_VOTING_PERIOD)
///           - a quorum and a simple majority are both required to execute
///           - a timelock separates "passed" from "executable" so holders can
///             react (and an executor can be front-run only after the delay)
///           - only (target, selector) pairs on an allowlist may be called, so
///             a proposal cannot smuggle an arbitrary call into a privileged
///             contract
///           - proposers post a bond, returned when their proposal passes and
///             forfeited (to the DAO owner) when it is rejected or misses quorum
///           - votes must be 1 (for) / 2 (against) / 3 (abstain)
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
        uint64 executeAfter;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        ProposalState state;
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, address indexed target, string title, uint64 votingEndsAt, uint64 executeAfter);
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint8 choice); // 1=for 2=against 3=abstain
    event ProposalExecuted(uint256 indexed proposalId, bytes result);
    event ProposalRejected(uint256 indexed proposalId);
    event TargetUpdated(address indexed target, bool allowed);
    event CallUpdated(address indexed target, bytes4 selector, bool allowed);
    event QuorumUpdated(uint256 previousQuorum, uint256 newQuorum);
    event MinVoterBalanceUpdated(uint256 previousBalance, uint256 newBalance);
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
    error ProposalFailed();
    error TargetNotAllowed();
    error CallNotAllowed();
    error NotOwner();
    error BadVotingPeriod();
    error BadChoice();
    error WrongBond();
    error QuorumNotMet();
    error TimelockActive();
    error VoterBelowMinimum();
    error TransferFailed();

    // ------------------------------------------------------------------
    // Constants / storage
    // ------------------------------------------------------------------

    uint64 public constant MIN_VOTING_PERIOD = 3 days;
    uint64 public constant MAX_VOTING_PERIOD = 14 days;
    uint64 public constant TIMELOCK = 2 days;
    uint256 public constant PROPOSER_BOND = 0.05 ether;

    uint8 internal constant CHOICE_FOR = 1;
    uint8 internal constant CHOICE_AGAINST = 2;
    uint8 internal constant CHOICE_ABSTAIN = 3;

    address public owner;
    /// @notice Minimum decisive votes (for + against) required to execute.
    uint256 public quorum = 3;
    /// @notice Native QOR balance a voter must hold to cast a vote (0 = open).
    ///         A cheap Sybil cost; combine with reputation/stake off-chain.
    uint256 public minVoterBalance = 0;

    mapping(address => bool) public allowedTargets;
    mapping(address => mapping(bytes4 => bool)) public allowedCalls;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    uint256 private _lock = 1;

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

    modifier nonReentrant() {
        if (_lock != 1) revert ProposalFailed();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ------------------------------------------------------------------
    // Configuration (owner; transfer ownership to the DAO after wiring)
    // ------------------------------------------------------------------

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        allowedTargets[target] = allowed;
        emit TargetUpdated(target, allowed);
    }

    /// @notice Allow or deny a specific (target, selector) pair.
    function setAllowedCall(address target, bytes4 selector, bool allowed) external onlyOwner {
        allowedCalls[target][selector] = allowed;
        emit CallUpdated(target, selector, allowed);
    }

    function setQuorum(uint256 newQuorum) external onlyOwner {
        emit QuorumUpdated(quorum, newQuorum);
        quorum = newQuorum;
    }

    function setMinVoterBalance(uint256 newBalance) external onlyOwner {
        emit MinVoterBalanceUpdated(minVoterBalance, newBalance);
        minVoterBalance = newBalance;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert NotOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Renounce ownership so no EOA can alter the allowlist.
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    // ------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------

    /// @notice Create a proposal that, if it passes and the timelock elapses,
    ///         executes `callData` against an allowlisted (target, selector).
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

        emit ProposalCreated(proposalId, msg.sender, target, title, p.votingEndsAt, p.executeAfter);
    }

    /// @notice One vote per wallet per proposal.
    function castVote(uint256 proposalId, uint8 choice) external {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp >= p.votingEndsAt) revert VotingClosed();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();
        if (choice != CHOICE_FOR && choice != CHOICE_AGAINST && choice != CHOICE_ABSTAIN) revert BadChoice();
        if (minVoterBalance > 0 && msg.sender.balance < minVoterBalance) revert VoterBelowMinimum();

        hasVoted[proposalId][msg.sender] = true;

        if (choice == CHOICE_FOR) {
            p.forVotes += 1;
        } else if (choice == CHOICE_AGAINST) {
            p.againstVotes += 1;
        } else {
            p.abstainVotes += 1;
        }

        emit VoteCast(proposalId, msg.sender, choice);
    }

    /// @notice Execute a passed proposal after the timelock, or finalize it as
    ///         rejected. Returns the proposer's bond on success.
    function execute(uint256 proposalId, string calldata description) external nonReentrant returns (bytes memory result) {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp < p.executeAfter) revert TimelockActive();
        if (keccak256(bytes(description)) != p.descriptionHash) revert DescriptionMismatch();

        bool passed = p.forVotes > p.againstVotes && (p.forVotes + p.againstVotes) >= quorum;

        if (!passed) {
            p.state = ProposalState.Rejected;
            _send(owner, PROPOSER_BOND); // forfeit to the DAO owner (or burn if renounced)
            emit ProposalRejected(proposalId);
            return "";
        }

        p.state = ProposalState.Executed;

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

        _send(p.proposer, PROPOSER_BOND);
        emit ProposalExecuted(proposalId, result);
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0 || to == address(0)) return; // renounced: bond stays in the DAO
        // A recipient that rejects the transfer simply leaves the bond in the
        // DAO; execution must never fail because of a bond payout.
        (bool ok,) = to.call{ value: amount }("");
        ok; // silence unused warning
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function isExecutable(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        return p.state == ProposalState.Open && block.timestamp >= p.executeAfter;
    }
}

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

