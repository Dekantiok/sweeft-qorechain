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
        bool delivered; // SELLER CLAIM: starts the buyer inspection window (not proof)
        bool fulfilledConfirmed; // buyer confirmed receipt (full release path)
        bool evidenceAttested; // verifier threshold OR carrier DELIVERED (proof)
        bool released;
        address verifier; // the verifier/carrier that pushed attestation over threshold
        // --- logistics (v4, appended for ABI compatibility) ---
        address logisticsPartner; // zero = physical-less / digital default
        uint256 logisticsAmount; // paid to partner, separate from seller goods
        bool carrierAttested; // signed carrier payload verified on-chain (any status)
        uint64 carrierAttestedAt;
        bytes32 carrierPayloadHash; // keccak256(canonical tracking payload)
        address carrierSigner;
        // --- v5 appended fields ---
        uint256 feeBpsSnapshot; // platform fee captured at creation
        address treasurySnapshot; // treasury captured at creation
        string carrierStatus; // last carrier status (e.g. DELIVERED, LOST)
        uint64 carrierIssuedAt; // carrier-claimed issue time (ms or s, opaque)
        uint8 verifierAttestations; // distinct verifier attestations recorded
        // --- v6 appended fields ---
        bool carrierDelivered; // PROOF: latest carrier status was DELIVERED (N-2)
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
    event CreditsAccrued(address indexed account, uint256 amount);
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
    error BadVerifierSignature();
    error VerifierKeyNotRegistered();
    error VerifierKeyNotProven();
    error UnsupportedKeyAlgorithm();
    error AlreadyAttested();
    error CarrierKeyNotRegistered();
    error CarrierKeyNotProven();
    error BadPayloadHash();
    error BadTimestamp();
    error StaleAttestation();
    error AlreadyWired();
    error BadStatus();
    error RegistryUnavailable();

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

    /// @notice Bounds on carrier-supplied strings stored in the escrow struct.
    uint256 public constant MAX_STATUS_LEN = 32;
    uint256 public constant MAX_TRACKING_LEN = 128;

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
    /// @notice Per-(carrier, escrow) nonce — single-use per shipment, so a
    ///         carrier's concurrent deliveries don't invalidate each other
    ///         (mirrors the per-escrow release nonce fix, C-9/N-6).
    mapping(address => mapping(uint256 => uint256)) public carrierNonce;

    /// @notice Per-(verifier, escrow) nonce: each verifier can attest each
    ///         escrow at most once, and a signature can never be replayed.
    mapping(address => mapping(uint256 => uint256)) public verifierNonce;
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

    /// @notice Only the deploying account (one-shot wiring, Stage 4 QC4-2 made
    ///         explicit as a named modifier).
    modifier onlyDeployer() {
        if (msg.sender != deployer) revert NotDeployer();
        _;
    }

    /// @notice Only the dispute board (N-1 made explicit as a named modifier).
    modifier onlyDisputeBoard() {
        if (msg.sender != disputeBoard) revert NotDisputeBoard();
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
    function setDisputeBoard(address board) external onlyDeployer {
        if (disputeBoard != address(0)) revert AlreadyWired();
        if (board == address(0)) revert InvalidParties();
        disputeBoard = board;
    }

    /// @notice Wire the Marketplace contract. Callable once by the deployer.
    function setMarketplace(address marketplaceAddress) external onlyDeployer {
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

    /// @notice Authorized verifier records a fulfilment attestation (Phase 3).
    ///         The caller may be any relayer; authorization comes from the
    ///         verifier's ML-DSA-87 signature, verified against its
    ///         chain-registered key via the PQC precompile. A stolen classical
    ///         key alone cannot manufacture an attestation. The signed
    ///         message binds chain, vault, registry, verifier identity, pinned
    ///         key version, escrow, evidence, issuance window and nonce.
    ///         An escrow becomes `evidenceAttested` once the registry
    ///         threshold is met (M-of-N), so one rogue verifier cannot on its
    ///         own block the buyer's refund path.
    function attestEvidence(
        uint256 escrowId,
        address verifier,
        bytes32 evidenceHash,
        uint64 issuedAt,
        uint64 expiresAt,
        bytes calldata signature
    ) external {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert InvalidEscrow();
        if (e.status != EscrowStatus.Funded) revert InvalidStatus();
        if (verifierAttested[escrowId][verifier]) revert AlreadyAttested();
        IExcaliburOracleRegistry reg = IExcaliburOracleRegistry(oracleRegistry);
        if (!reg.isVerifier(verifier)) revert NotVerifier();
        // Fail closed when the registry pins no key (pre-hardening verifier).
        uint8 pinnedVersion = reg.keyVersion(verifier);
        if (pinnedVersion == 0) revert NotVerifier();
        if (issuedAt > block.timestamp) revert BadTimestamp();
        if (expiresAt != issuedAt + MAX_ATTEST_AGE) revert StaleAttestation();
        if (block.timestamp > expiresAt) revert StaleAttestation();

        uint256 nonce = verifierNonce[verifier][escrowId];
        bytes memory message = _verifierMessage(verifier, pinnedVersion, escrowId, evidenceHash, issuedAt, expiresAt, nonce);
        _requireVerifierSignature(verifier, message, signature);
        // Nonce consumed only after every check above passed, just before the
        // state transition (a revert never leaves it consumed).
        verifierNonce[verifier][escrowId] = nonce + 1;
        verifierAttested[escrowId][verifier] = true;

        uint8 count = e.verifierAttestations + 1;
        e.verifierAttestations = count;
        verifierAttestCount[escrowId] = count;
        emit EvidenceAttested(escrowId, verifier, evidenceHash);

        if (count >= _verifierThreshold()) {
            e.evidenceAttested = true;
            e.verifier = verifier;
            emit VerifierThresholdReached(escrowId, count);
        }
    }

    /// @notice Verify the carrier's ML-DSA-87 signature over a versioned,
    ///         domain-separated authorization (`sweeft-carrier-v2`, Phase 2):
    ///         chain, vault, carrier identity, provider, escrow, tracking
    ///         hash, status, evidence hash, issuance, expiry and nonce are all
    ///         bound into the signed bytes, so a signature is usable only for
    ///         this deployment, this escrow, this evidence and this window.
    ///         Only a `DELIVERED` status counts as proof of delivery; any
    ///         other status is recorded (latest-status rule) and leaves the
    ///         buyer's refund path open.
    /// @param evidenceHash hash of the evidence content being delivered.
    /// @param expiresAt must equal `issuedAt + MAX_ATTEST_AGE`.
    function attestCarrierEvidence(
        uint256 escrowId,
        string calldata trackingNumber,
        string calldata status,
        bytes32 evidenceHash,
        uint64 issuedAt,
        uint64 expiresAt,
        bytes calldata signature
    ) external {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert InvalidEscrow();
        if (e.status != EscrowStatus.Funded) revert InvalidStatus();
        // Bound carrier-supplied strings so they cannot bloat getEscrow() gas (N-7).
        if (bytes(status).length == 0 || bytes(status).length > MAX_STATUS_LEN) revert BadStatus();
        if (bytes(trackingNumber).length == 0 || bytes(trackingNumber).length > MAX_TRACKING_LEN) revert BadStatus();
        // The caller must be the escrow's assigned partner AND still
        // registered (removing a carrier revokes attest authority, F8).
        if (e.logisticsPartner == address(0) || msg.sender != e.logisticsPartner) revert NotCarrier();
        if (!isCarrier[msg.sender]) revert NotCarrier();
        // Expiry is pinned to issuance + the max age: the signer cannot widen
        // the signature's own window, and old signatures die after 7 days.
        if (issuedAt > block.timestamp) revert BadTimestamp();
        if (expiresAt != issuedAt + MAX_ATTEST_AGE) revert StaleAttestation();
        if (block.timestamp > expiresAt) revert StaleAttestation();

        uint256 nonce = carrierNonce[msg.sender][escrowId];
        bytes memory message = _carrierMessage(
            msg.sender, escrowId, trackingNumber, status, evidenceHash, issuedAt, expiresAt, nonce
        );
        _requireCarrierSignature(msg.sender, message, signature);
        // Consume the nonce only after every check above passed (the
        // signature is the last gate), immediately before state changes.
        carrierNonce[msg.sender][escrowId] = nonce + 1;

        bool deliveredStatus = keccak256(bytes(status)) == keccak256(bytes("DELIVERED"));

        e.carrierAttested = true;
        e.carrierAttestedAt = uint64(block.timestamp);
        e.carrierPayloadHash = keccak256(message);
        e.carrierSigner = msg.sender;
        e.carrierStatus = status;
        e.carrierIssuedAt = issuedAt;
        // Latest-status rule (N-8): a DELIVERED attestation can be superseded by
        // a later LOST/RETURNED one, and vice-versa. Only DELIVERED is proof of
        // delivery — the seller's markDelivered claim is tracked separately.
        e.carrierDelivered = deliveredStatus;
        e.evidenceAttested = deliveredStatus || (e.verifierAttestations >= _verifierThreshold());

        emit CarrierAttested(escrowId, msg.sender, e.carrierPayloadHash, status, trackingNumber);
    }

    /// @notice Release escrowed funds to the seller, charging the platform fee.
    ///         Settlement is credits-only (Stage 5 QC4-1): the vault makes NO
    ///         external calls while settling — every share is credited and
    ///         withdrawn later via `withdrawCredits`, so there is no
    ///         re-entrancy surface in the money path at all.
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

        _settleRelease(escrowId, e);
    }

    /// @notice Refund the buyer when the seller never delivered and no verifier
    ///         or carrier confirmed fulfilment. Credited, not pushed (see
    ///         `release` for the credits-only settlement note).
    function refundAfterDeadline(uint256 escrowId, bytes calldata signature) external nonReentrant {
        if (!isRefundable(escrowId)) revert NotRefundable();

        Escrow storage e = escrows[escrowId];
        uint256 nonce = escrowNonce[escrowId];
        bytes memory message = _refundMessage(escrowId, e.buyer, e.buyer, e.amount, nonce);
        _requirePqcSignature(e.buyer, message, signature);

        escrowNonce[escrowId] = nonce + 1;
        e.status = EscrowStatus.Refunded;

        emit EscrowRefunded(escrowId, e.buyer, e.amount, nonce);

        _credit(e.buyer, e.amount);
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

    /// @notice Freeze a funded escrow for dispute resolution. Only the dispute
    ///         board may call this — it validates the raiser (buyer/seller),
    ///         collects the raiser bond, and is the only party that can settle.
    ///         A direct buyer/seller call is rejected so a party can never
    ///         freeze an escrow without a bond or a resolvable path (N-1).
    function raiseDispute(uint256 escrowId) external onlyDisputeBoard {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert InvalidEscrow();
        if (e.status != EscrowStatus.Funded) revert NotDisputable();

        e.status = EscrowStatus.Disputed;
        emit DisputeRaised(escrowId, msg.sender);
    }

    /// @notice Settle a disputed escrow. Only the dispute board contract may
    ///         call this; the board reaches a 2-of-3 resolver majority.
    function resolveDispute(uint256 escrowId, bool releaseToSeller) external nonReentrant onlyDisputeBoard {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Disputed) revert InvalidStatus();

        uint256 fee = 0;
        if (releaseToSeller) {
            e.released = true;
            e.status = EscrowStatus.Completed;
            fee = _feeForAmount(e.amount - e.logisticsAmount, e.feeBpsSnapshot);
            _settleRelease(escrowId, e);
        } else {
            e.status = EscrowStatus.Refunded;
            _credit(e.buyer, e.amount);
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
        // PROOF only: a seller's markDelivered claim is not enough to make the
        // escrow releasable (N-2). The buyer can always confirm receipt.
        if ((e.carrierDelivered || e.evidenceAttested) && block.timestamp >= e.deliveryDeadline) {
            return true;
        }
        return false;
    }

    function isRefundable(uint256 escrowId) public view returns (bool) {
        Escrow storage e = escrows[escrowId];
        if (e.status != EscrowStatus.Funded) return false;
        // Only PROOF of delivery (verifier threshold or a carrier DELIVERED
        // attestation) blocks a refund. The seller's markDelivered claim alone
        // does NOT — otherwise a seller could freeze the buyer's escape hatch
        // and let a no-show dispute default to release (N-2).
        if (e.evidenceAttested || e.carrierDelivered) return false;
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
        // Explicit bounds (QC4-3): bps is capped at MAX_FEE_BPS and the
        // product is overflow-checked, so amount * bps can never wrap.
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        if (bps > 0 && amount > type(uint256).max / bps) revert InvalidAmount();
        return (amount * bps) / 10_000;
    }

    /// @dev Credits-only settlement (Stage 5 QC4-1): no external calls while
    ///      settling, so the money path has no re-entrancy surface. Every
    ///      recipient withdraws later via `withdrawCredits` (checks-effects-
    ///      interactions, zeroed before the single call there).
    function _credit(address to, uint256 amount) internal {
        if (amount == 0) return;
        credits[to] += amount;
        emit CreditsAccrued(to, amount);
    }

    function _settleRelease(uint256 escrowId, Escrow storage e) internal {
        uint256 goodsAmount = e.amount - e.logisticsAmount;

        _creditCarrier(escrowId, e);

        uint256 fee = _feeForAmount(goodsAmount, e.feeBpsSnapshot);
        _creditFees(escrowId, e, fee);

        _credit(e.seller, goodsAmount - fee);
    }

    function _creditCarrier(uint256 escrowId, Escrow storage e) internal {
        if (e.logisticsAmount == 0 || e.logisticsPartner == address(0)) return;
        // The carrier is paid only on PROVEN delivery (a DELIVERED
        // attestation), never on a mere in-transit status (N-2).
        if (e.carrierDelivered) {
            _credit(e.logisticsPartner, e.logisticsAmount);
            emit LogisticsPaid(escrowId, e.logisticsPartner, e.logisticsAmount);
        } else {
            _credit(e.buyer, e.logisticsAmount);
            emit LogisticsHeld(escrowId, e.buyer, e.logisticsAmount);
        }
    }

    function _creditFees(uint256 escrowId, Escrow storage e, uint256 fee) internal {
        if (fee == 0) return;
        uint256 treasuryShare = (fee * TREASURY_SHARE_BPS) / 10_000;
        uint256 disputeShare = fee - treasuryShare;

        if (disputeBoard == address(0)) {
            treasuryShare = fee;
            disputeShare = 0;
        }

        _credit(e.treasurySnapshot, treasuryShare);
        _credit(disputeBoard, disputeShare);

        emit FeeCollected(escrowId, treasuryShare, disputeShare);
    }

    /// @notice Typed registry reads (Stage 5 QC4-5): the low-level
    ///         `staticcall` pattern is gone; calls go through an interface and
    ///         fail closed if the registry cannot be read.
    function _verifierThreshold() internal view returns (uint8) {
        uint8 t = IExcaliburOracleRegistry(oracleRegistry).threshold();
        // Fail closed (N-9): a registry reporting 0 means "any".
        return t == 0 ? 1 : t;
    }

    function _requireCarrierSignature(address carrier, bytes memory message, bytes calldata signature) internal view {
        (bool registered,, bytes memory pubkey, bool proven) = PQC_KEYS.pqcKeyStatus(carrier);
        if (!registered || pubkey.length == 0) revert CarrierKeyNotRegistered();
        if (!proven) revert CarrierKeyNotProven();
        if (!PQC_VERIFY.pqcVerify(pubkey, signature, message)) revert BadCarrierSignature();
    }

    /// @notice Public rebuild of the v2 carrier authorization message, so
    ///         signing clients (Django, wallets, other integrators) can
    ///         construct byte-identical payloads without reimplementing the
    ///         string encoding.
    function buildCarrierMessage(
        address carrier,
        uint256 escrowId,
        string memory trackingNumber,
        string memory status,
        bytes32 evidenceHash,
        uint64 issuedAt,
        uint64 expiresAt,
        uint256 nonce
    ) external view returns (bytes memory) {
        return _carrierMessage(carrier, escrowId, trackingNumber, status, evidenceHash, issuedAt, expiresAt, nonce);
    }

    /// @notice Public rebuild of the v1 verifier attestation message.
    function buildVerifierMessage(
        address verifier,
        uint8 keyVersion,
        uint256 escrowId,
        bytes32 evidenceHash,
        uint64 issuedAt,
        uint64 expiresAt,
        uint256 nonce
    ) external view returns (bytes memory) {
        return _verifierMessage(verifier, keyVersion, escrowId, evidenceHash, issuedAt, expiresAt, nonce);
    }

    /// @notice Versioned, domain-separated verifier authorization (Phase 3):
    ///         verifier ML-DSA-87 signature over chain, vault, registry,
    ///         verifier identity, pinned key version, escrow, evidence,
    ///         issuance window and nonce.
    function _verifierMessage(
        address verifier,
        uint8 keyVersion,
        uint256 escrowId,
        bytes32 evidenceHash,
        uint64 issuedAt,
        uint64 expiresAt,
        uint256 nonce
    ) internal view returns (bytes memory) {
        return bytes(
            string.concat(
                "sweeft-verifier-v1|chain=",
                cosmosChainId,
                "|vault=",
                _toHexString(address(this)),
                "|registry=",
                _toHexString(oracleRegistry),
                "|verifier=",
                _toHexString(verifier),
                "|keyVersion=",
                _uintToString(uint256(keyVersion)),
                "|escrow=",
                _uintToString(escrowId),
                "|evidence=",
                _toHexBytes32(evidenceHash),
                "|issued=",
                _uintToString(uint256(issuedAt)),
                "|expires=",
                _uintToString(uint256(expiresAt)),
                "|nonce=",
                _uintToString(nonce)
            )
        );
    }

    function _requireVerifierSignature(address verifier, bytes memory message, bytes calldata signature) internal view {
        (bool registered, uint8 algorithmId, bytes memory pubkey, bool proven) = PQC_KEYS.pqcKeyStatus(verifier);
        if (!registered || pubkey.length == 0) revert VerifierKeyNotRegistered();
        if (!proven) revert VerifierKeyNotProven();
        if (algorithmId != 1) revert UnsupportedKeyAlgorithm();
        if (!PQC_VERIFY.pqcVerify(pubkey, signature, message)) revert BadVerifierSignature();
    }

    /// @notice Versioned, domain-separated carrier authorization (Phase 2).
    ///         Binds protocol+schema, chain, vault, carrier, provider, escrow,
    ///         tracking hash, status, evidence hash, issuance window and nonce.
    function _carrierMessage(
        address carrier,
        uint256 escrowId,
        string memory trackingNumber,
        string memory status,
        bytes32 evidenceHash,
        uint64 issuedAt,
        uint64 expiresAt,
        uint256 nonce
    ) internal view returns (bytes memory) {
        return bytes(
            string.concat(
                "sweeft-carrier-v2|chain=",
                cosmosChainId,
                "|vault=",
                _toHexString(address(this)),
                "|carrier=",
                _toHexString(carrier),
                "|provider=",
                carrierProviderId[carrier],
                "|escrow=",
                _uintToString(escrowId),
                "|trackingHash=",
                _toHexBytes32(keccak256(bytes(trackingNumber))),
                "|status=",
                status,
                "|evidence=",
                _toHexBytes32(evidenceHash),
                "|issued=",
                _uintToString(uint256(issuedAt)),
                "|expires=",
                _uintToString(uint256(expiresAt)),
                "|nonce=",
                _uintToString(nonce)
            )
        );
    }

    function _toHexBytes32(bytes32 value) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes32 b = value;
        bytes memory out = new bytes(66);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            out[2 + i * 2] = alphabet[uint8(b[i] >> 4)];
            out[3 + i * 2] = alphabet[uint8(b[i] & 0x0f)];
        }
        return string(out);
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

/// @notice Typed view of the verifier registry (Stage 5 QC4-5: replaces the
///         low-level `staticcall` pattern with checked interface calls).
interface IExcaliburOracleRegistry {
    function isVerifier(address account) external view returns (bool);
    function threshold() external view returns (uint8);
    function keyVersion(address verifier) external view returns (uint8);
}

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
    error QuoteExpired();
    error BadQuoteSignature();
    error QuoteReplayed();
    error SellerKeyNotRegistered();
    error SellerKeyNotProven();

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    SweeftVault public immutable vault;

    // QoreChain PQC precompiles (same addresses as SweeftVault).
    IPQCVerify internal constant PQC_VERIFY = IPQCVerify(0x0000000000000000000000000000000000000a01);
    IPQCKeyStatus internal constant PQC_KEYS = IPQCKeyStatus(0x0000000000000000000000000000000000000a02);

    uint256 public listingCount;
    mapping(uint256 => Listing) public listings;

    /// @notice Per-(listing, buyer) quote nonce: the only nonce a seller
    ///         signature is valid for. Advances on each quoted purchase,
    ///         so a captured quote signature can never be replayed.
    mapping(uint256 => mapping(address => uint256)) public quoteNonce;

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

    /// @notice Build the exact signed payload for a seller quote (Phase 3).
    ///         Returns the full payload the seller's ML-DSA-87 signature is
    ///         verified over: the QoreChain domain prefix
    ///         ("qorechain-msg-v1|" + chainId + "|", as in SweeftVault)
    ///         followed by the `sweeft-quote-v1` inner message. The seller
    ///         is read from the on-chain listing, so it cannot be forged
    ///         separately from the signed wire; `price` is the quoted price
    ///         (bounded by the listing price in `purchaseWithQuote`).
    function buildQuoteMessage(uint256 listingId, address buyer, uint256 price, uint64 expiresAt, uint256 nonce)
        external
        view
        returns (bytes memory)
    {
        return _quotePayload(listingId, buyer, price, expiresAt, nonce);
    }

    /// @notice Buy a listing at a seller-signed quoted price. The seller's
    ///         ML-DSA-87 signature authenticates (listing, seller, buyer,
    ///         quoted price, expiry, nonce) via the PQC precompiles; the
    ///         nonce is the buyer's current `quoteNonce` for this listing
    ///         and is consumed on success, so a quote cannot be replayed.
    /// @param listingId the listing to buy
    /// @param deliveryDeadline unix seconds; must satisfy the vault's window
    /// @param quotePrice the seller-quoted price (must be <= listing price)
    /// @param expiresAt unix seconds after which the quote is invalid
    /// @param signature seller's ML-DSA-87 signature over buildQuoteMessage(...)
    function purchaseWithQuote(
        uint256 listingId,
        uint64 deliveryDeadline,
        uint256 quotePrice,
        uint64 expiresAt,
        bytes calldata signature
    ) external payable returns (uint256 escrowId) {
        Listing storage listing = listings[listingId];
        if (listing.status != ListingStatus.Active) revert ListingNotActive();
        if (listing.quantity == 0) revert OutOfStock();
        if (msg.sender == listing.seller) revert InvalidBuyer();
        if (quotePrice == 0) revert InvalidPrice();
        if (quotePrice > listing.price) revert PriceAboveMax();
        if (msg.value != quotePrice) revert WrongPayment();
        if (expiresAt <= block.timestamp) revert QuoteExpired();

        uint256 nonce = quoteNonce[listingId][msg.sender];
        // `nonce` is by construction the current quoteNonce for this
        // (listing, buyer); a signature for any other nonce fails below.

        (bool registered,, bytes memory pubkey, bool proven) = PQC_KEYS.pqcKeyStatus(listing.seller);
        if (!registered || pubkey.length == 0) revert SellerKeyNotRegistered();
        if (!proven) revert SellerKeyNotProven();

        bytes memory payload = _quotePayload(listingId, msg.sender, quotePrice, expiresAt, nonce);
        if (!PQC_VERIFY.pqcVerify(pubkey, signature, payload)) {
            // Distinguish a replayed quote (valid for the previous nonce)
            // from a signature that was never valid for this buyer.
            if (nonce > 0) {
                bytes memory replayed =
                    _quotePayload(listingId, msg.sender, quotePrice, expiresAt, nonce - 1);
                if (PQC_VERIFY.pqcVerify(pubkey, signature, replayed)) revert QuoteReplayed();
            }
            revert BadQuoteSignature();
        }

        // Consume the nonce only after the signature verified, immediately
        // before state changes (a revert above leaves it unconsumed).
        quoteNonce[listingId][msg.sender] = nonce + 1;

        listing.quantity -= 1;
        if (listing.quantity == 0) {
            listing.status = ListingStatus.Sold;
        }
        listing.updatedAt = uint64(block.timestamp);

        escrowId = vault.createEscrowWithLogistics{ value: msg.value }(
            msg.sender, listing.seller, listing.logisticsPartner, deliveryDeadline, msg.value, listing.logisticsFee
        );

        emit ListingPurchased(listingId, escrowId, msg.sender, listing.seller, quotePrice);
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

    function _quotePayload(uint256 listingId, address buyer, uint256 price, uint64 expiresAt, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        address seller = listings[listingId].seller;
        bytes memory inner = bytes(
            string.concat(
                "sweeft-quote-v1|marketplace=",
                _toHexString(address(this)),
                "|listing=",
                _uintToString(listingId),
                "|seller=",
                _toHexString(seller),
                "|buyer=",
                _toHexString(buyer),
                "|price=",
                _uintToString(price),
                "|expires=",
                _uintToString(uint256(expiresAt)),
                "|nonce=",
                _uintToString(nonce)
            )
        );
        return abi.encodePacked("qorechain-msg-v1|", vault.cosmosChainId(), "|", inner);
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
// Precompile interfaces (minimal duplicates of SweeftVault's)
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

// ============ SweeftOracleRegistry.sol ============
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SweeftOracleRegistry — authorized fulfilment verifiers
/// @notice Records who may attest fulfilment for escrows, the M-of-N threshold
///         the Vault requires, and a per-verifier bond the DAO can slash for a
///         provably false attestation (N-9). Ownership transfers to the DAO
///         after deployment.
/// @notice Post-quantum key state bound at registration (Phase 3 hardening):
///         each verifier is pinned to the algorithmId of its chain-registered
///         ML-DSA-87 key, plus the registration timestamp. Vault attestations
///         must be signed under the currently pinned version, so revocation
///         and rotation fail closed for pending signatures.
contract SweeftOracleRegistry {
    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event VerifierAdded(address indexed verifier);
    event VerifierRemoved(address indexed verifier);
    event KeyVersionRotated(address indexed verifier, uint8 previousVersion, uint8 newVersion);
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
    error KeyNotRegistered();
    error KeyNotProven();
    error UnsupportedKeyAlgorithm();

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

    /// @notice ML-DSA algorithmId pinned at registration (1 = ML-DSA-87).
    ///         Attestations must be signed under the currently pinned
    ///         version; rotation re-pins it and pending signatures fail.
    mapping(address => uint8) public keyVersion;
    /// @notice Registry timestamp of the verifier's current key pin.
    mapping(address => uint64) public keyRegisteredAt;

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

        // Verifier must hold a chain-registered, proven ML-DSA-87 key; pin its
        // algorithm version so attestations prove which key authorized them.
        (bool registered, uint8 algorithmId, bytes memory pubkey, bool proven) = IPQCKeyStatus(
            0x0000000000000000000000000000000000000a02
        ).pqcKeyStatus(verifier);
        if (!registered || pubkey.length == 0) revert KeyNotRegistered();
        if (!proven) revert KeyNotProven();
        if (algorithmId != 1) revert UnsupportedKeyAlgorithm();

        isVerifier[verifier] = true;
        verifierCount += 1;
        keyVersion[verifier] = algorithmId;
        keyRegisteredAt[verifier] = uint64(block.timestamp);
        emit VerifierAdded(verifier);
    }

    /// @notice Re-pin a verifier's key version after it rotates its PQ key
    ///         (registered + proven on chain, same or newer algorithm).
    ///         Pending attestations signed under the old version fail.
    function rotateKeyVersion(address verifier) external onlyOwner {
        if (!isVerifier[verifier]) revert NotVerifier();
        (bool registered, uint8 algorithmId, bytes memory pubkey, bool proven) = IPQCKeyStatus(
            0x0000000000000000000000000000000000000a02
        ).pqcKeyStatus(verifier);
        if (!registered || pubkey.length == 0) revert KeyNotRegistered();
        if (!proven) revert KeyNotProven();
        if (algorithmId != 1) revert UnsupportedKeyAlgorithm();

        uint8 previous = keyVersion[verifier];
        keyVersion[verifier] = algorithmId;
        keyRegisteredAt[verifier] = uint64(block.timestamp);
        emit KeyVersionRotated(verifier, previous, algorithmId);
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

/// @notice Read-only view of the chain PQC registry (testnet precompile).
interface IPQCKeyStatus {
    function pqcKeyStatus(address account)
        external
        view
        returns (bool registered, uint8 algorithmId, bytes memory pubkey, bool proven);
}

// ============ SweeftDisputeBoard.sol ============
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
        // --- randomness (Phase 5): committed at open/appeal time, drawn from
        // a fixed future block. captureSeed = prevrandao at open/appeal;
        // drawSeed = blockhash(drawBlock) checkpointed by anyone within the
        // 256-block availability window. Caller timing cannot influence either.
        uint64 drawBlock;
        uint64 appealDrawBlock;
        bytes32 captureSeed;
        bytes32 appealCaptureSeed;
        bytes32 drawSeed;
        bytes32 appealDrawSeed;
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
    event SeedCheckpointed(uint256 indexed disputeId, uint8 round, bytes32 seed);
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
    error TooLateForCheckpoint();
    error SeedNotReady();
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

    /// @notice Blocks after a dispute/appeal opens at which the seed block
    ///         lands. The hash of this future block is unknowable when the
    ///         dispute opens, so neither timing calls nor the raiser can
    ///         choose a favorable panel (Phase 5).
    uint64 public constant DRAW_BLOCK_DELAY = 16;

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
        // Randomness commitment (Phase 5): fix the seed block NOW (16 blocks
        // ahead — its hash is unknowable at this point) and capture the one
        // prevrandao value as the liveness fallback.
        d.drawBlock = uint64(block.number) + DRAW_BLOCK_DELAY;
        d.captureSeed = bytes32(block.prevrandao);

        emit DisputeOpened(disputeId, escrowId, msg.sender, d.joinEndsAt, d.votingEndsAt, msg.value);
    }

    /// @notice Checkpoint the draw-block hash for the first panel. Permissionless
    ///         and callable any time after `drawBlock` passes (blockhashes are
    ///         only served for 256 blocks, so callers are urged to run this
    ///         within that window — the capture-seed fallback keeps selection
    ///         live if nobody does).
    function checkpointSeed(uint256 disputeId) external returns (bytes32) {
        Dispute storage d = disputes[disputeId];
        if (d.drawBlock == 0) revert UnknownDispute();
        if (d.drawSeed != bytes32(0)) return d.drawSeed;
        bytes32 h = blockhash(d.drawBlock);
        if (h == bytes32(0)) revert TooLateForCheckpoint();
        d.drawSeed = h;
        emit SeedCheckpointed(disputeId, 1, h);
        return h;
    }

    /// @notice Same for the appeal panel's seed block.
    function checkpointAppealSeed(uint256 disputeId) external returns (bytes32) {
        Dispute storage d = disputes[disputeId];
        if (d.appealDrawBlock == 0) revert UnknownDispute();
        if (d.appealDrawSeed != bytes32(0)) return d.appealDrawSeed;
        bytes32 h = blockhash(d.appealDrawBlock);
        if (h == bytes32(0)) revert TooLateForCheckpoint();
        d.appealDrawSeed = h;
        emit SeedCheckpointed(disputeId, 2, h);
        return h;
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
        if (block.number <= d.drawBlock) revert SeedNotReady();

        // Opportunistically checkpoint the seed block while it is fresh.
        if (d.drawSeed == bytes32(0)) {
            bytes32 h = blockhash(d.drawBlock);
            if (h != bytes32(0)) {
                d.drawSeed = h;
                emit SeedCheckpointed(disputeId, 1, h);
            }
        }

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
        d.appellant = msg.sender;
        d.appealBond = msg.value;
        d.appealVotingEndsAt = uint64(block.timestamp) + votingPeriod;
        // Appeal seed commitment (Phase 5): same scheme as the first panel —
        // the panel is drawn later by `drawAppealPanel`, never in this tx,
        // so the appellant cannot grind randomness by choosing appeal timing.
        d.appealDrawBlock = uint64(block.number) + DRAW_BLOCK_DELAY;
        d.appealCaptureSeed = bytes32(block.prevrandao);

        // Keep the first panel's stake exposed while the appeal is decided.
        for (uint256 i = 0; i < d.memberCount; i++) {
            _extendLock(d.members[i], d.appealVotingEndsAt + appealWindow);
        }

        emit AppealOpened(disputeId, d.escrowId, msg.sender, d.appealVotingEndsAt, msg.value);
    }

    /// @notice Draw the appeal panel after the appeal seed block passes.
    ///         Permissionless; a full panel needs 5 eligible resolvers.
    function drawAppealPanel(uint256 disputeId) external {
        Dispute storage d = disputes[disputeId];
        if (d.state != DisputeState.Appealed) revert DisputeNotOpen();
        if (d.appealSelected) revert PanelAlreadySelected();
        if (block.timestamp >= d.appealVotingEndsAt) revert VotingClosed();
        if (block.number <= d.appealDrawBlock) revert SeedNotReady();

        if (d.appealDrawSeed == bytes32(0)) {
            bytes32 h = blockhash(d.appealDrawBlock);
            if (h != bytes32(0)) {
                d.appealDrawSeed = h;
                emit SeedCheckpointed(disputeId, 2, h);
            }
        }

        SweeftVault.Escrow memory escrow = vault.getEscrow(d.escrowId);
        uint8 chosen = _drawPanel(d, escrow, APPEAL_BOARD_SIZE, 2);
        d.appealSelected = true;
        d.appealMemberCount = chosen;

        for (uint256 i = 0; i < chosen; i++) {
            _extendLock(d.appealMembers[i], d.appealVotingEndsAt + appealWindow);
        }

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
    /// @notice Absolute attempt cap so gas stays bounded even for huge pools.
    uint256 public constant MAX_DRAW_ATTEMPTS = 128;

    function _drawPanel(
        Dispute storage d,
        SweeftVault.Escrow memory escrow,
        uint256 size,
        uint8 round
    ) internal returns (uint8 chosen) {
        uint256 required = minStakeFor(escrow.amount);
        uint256 n = resolverPool.length;
        if (n == 0) return 0;

        // Seed base (Phase 5): chained future-block hash when checkpointed,
        // else the capture-time prevrandao. Caller timing (selectPanel when)
        // never enters the seed, so panels cannot be ground by timing.
        bytes32 seedBase;
        if (round == 2) {
            seedBase = d.appealDrawSeed == bytes32(0)
                ? d.appealCaptureSeed
                : keccak256(abi.encode(d.appealDrawSeed, d.appealCaptureSeed));
        } else {
            seedBase = d.drawSeed == bytes32(0)
                ? d.captureSeed
                : keccak256(abi.encode(d.drawSeed, d.captureSeed));
        }

        // Bounded for-loop: at most min(n * MAX_DRAW_ATTEMPTS_PER_POOL,
        // MAX_DRAW_ATTEMPTS) iterations, whatever the pool contains
        // (parties/verifier/carrier are skipped).
        uint256 maxAttempts = n * MAX_DRAW_ATTEMPTS_PER_POOL;
        if (maxAttempts > MAX_DRAW_ATTEMPTS) maxAttempts = MAX_DRAW_ATTEMPTS;
        for (uint256 attempts; attempts < maxAttempts && chosen < size; attempts++) {
            uint256 idx = uint256(
                keccak256(abi.encode(seedBase, d.escrowId, round, chosen, attempts))
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

    /// @notice Pull a credit the Vault accrued for the board (the Vault's
    ///         credits-only settlement credits the board's fee share instead
    ///         of pushing it) into the reward pool (N-4).
    function withdrawVaultCredits() external nonReentrant {
        uint256 amount = vault.credits(address(this));
        if (amount == 0) revert ZeroAmount();
        vault.withdrawCredits();
        rewardPool += amount;
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

// ============ SweeftDAO2.sol ============
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SweeftDAO2 — stake-weighted proposal registry
/// @notice Governs Sweeft parameters. Executed proposals call allowlisted
///         (target, selector) pairs only.
///
///         Voting is stake-weighted (v6, N-5): a voter escrows QOR with their
///         vote and the escrowed amount is their voting power. The stake is
///         locked until the proposal reaches a final state, so a Sybil cartel
///         must lock real capital for every vote — three throwaway wallets no
///         longer pass a proposal for free. Quorum is measured in escrowed
///         stake, not wallet count.
///
///         Other hardening:
///           - a guardian may veto a passed proposal during the timelock
///             (a temporary safety valve; renounceable)
///           - self-governance selectors require a higher `criticalQuorumStake`
///           - proposals can be cancelled (by the proposer) or expired, and a
///             passed-but-reverting proposal is marked `Failed` rather than
///             left `Open` forever
///           - forfeited bonds go to a `treasury` (EOA/DAO), and failed pushes
///             become pull-payments (`pendingReturns`, `treasuryCredits`)
contract SweeftDAO2 {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum ProposalState {
        None,
        Open,
        Executed,
        Rejected,
        Cancelled,
        Expired,
        Failed,
        Vetoed
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

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, address indexed target, string title, uint64 votingEndsAt, uint64 executeAfter, bool critical);
    event VoteCast(uint256 indexed proposalId, address indexed voter, uint8 choice);
    event VoteStakeWithdrawn(uint256 indexed proposalId, address indexed voter, uint256 amount);
    event ProposalExecuted(uint256 indexed proposalId, bytes result);
    event ProposalRejected(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event ProposalExpired(uint256 indexed proposalId);
    event ProposalFailed(uint256 indexed proposalId, bytes reason);
    event ProposalVetoed(uint256 indexed proposalId, address indexed guardian);
    event TargetUpdated(address indexed target, bool allowed);
    event CallUpdated(address indexed target, bytes4 selector, bool allowed, bool critical);
    event QuorumUpdated(uint256 previousQuorum, uint256 newQuorum);
    event CriticalQuorumUpdated(uint256 previousQuorum, uint256 newQuorum);
    event MinVoteStakeUpdated(uint256 previousStake, uint256 newStake);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ReturnWithdrawn(address indexed account, uint256 amount);
    event TreasuryCreditsWithdrawn(address indexed treasury, uint256 amount);
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
    error TargetNotAllowed();
    error CallNotAllowed();
    error NotOwner();
    error NotGuardian();
    error NotProposer();
    error NotTreasury();
    error BadVotingPeriod();
    error BadChoice();
    error WrongBond();
    error QuorumNotMet();
    error TimelockActive();
    error TimelockOver();
    error VoteStakeTooLow();
    error NoVoteStake();
    error VoteStakeLocked();
    error NothingToWithdraw();
    error TransferFailed();
    error ProposalNotExpired();

    // ------------------------------------------------------------------
    // Constants / storage
    // ------------------------------------------------------------------

    uint64 public constant MIN_VOTING_PERIOD = 3 days;
    uint64 public constant MAX_VOTING_PERIOD = 14 days;
    uint64 public constant TIMELOCK = 2 days;
    uint64 public constant PROPOSAL_TTL = 30 days;
    uint256 public constant PROPOSER_BOND = 0.05 ether;

    uint8 internal constant CHOICE_FOR = 1;
    uint8 internal constant CHOICE_AGAINST = 2;
    uint8 internal constant CHOICE_ABSTAIN = 3;

    address public owner;
    /// @notice Temporary safety valve: may veto a passed proposal during the
    ///         timelock. Renounceable via `setGuardian(address(0))`.
    address public guardian;
    /// @notice Receives forfeited proposer bonds (never left stranded).
    address public treasury;

    /// @notice Minimum QOR a voter must escrow with their vote.
    uint256 public minVoteStake = 0.01 ether;
    /// @notice Quorum, measured in escrowed voting stake (wei), for ordinary
    ///         proposals. Default: three minimum stakes.
    uint256 public quorumStake = 0.03 ether;
    /// @notice Higher quorum for self-governance selectors.
    uint256 public criticalQuorumStake = 0.05 ether;

    mapping(address => bool) public allowedTargets;
    mapping(address => mapping(bytes4 => bool)) public allowedCalls;
    mapping(address => mapping(bytes4 => bool)) public criticalCalls;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    /// @notice QOR escrowed with a vote, withdrawable once the proposal is final.
    mapping(uint256 => mapping(address => uint256)) public voteStake;

    /// @notice Pull-payment credits for a bond/treasury push that failed.
    mapping(address => uint256) public pendingReturns;
    uint256 public treasuryCredits;

    uint256 private _lock = 1;

    constructor(address[] memory initialTargets) {
        owner = msg.sender;
        guardian = msg.sender;
        treasury = msg.sender;
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
        if (_lock != 1) revert ProposalNotOpen();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        allowedTargets[target] = allowed;
        emit TargetUpdated(target, allowed);
    }

    function setAllowedCall(address target, bytes4 selector, bool allowed) external onlyOwner {
        allowedCalls[target][selector] = allowed;
        emit CallUpdated(target, selector, allowed, criticalCalls[target][selector]);
    }

    /// @notice Mark a (target, selector) as self-governance-critical, requiring
    ///         `criticalQuorumStake`.
    function setCriticalCall(address target, bytes4 selector, bool critical) external onlyOwner {
        criticalCalls[target][selector] = critical;
        emit CallUpdated(target, selector, allowedCalls[target][selector], critical);
    }

    function setQuorumStake(uint256 newQuorum) external onlyOwner {
        emit QuorumUpdated(quorumStake, newQuorum);
        quorumStake = newQuorum;
    }

    function setCriticalQuorumStake(uint256 newQuorum) external onlyOwner {
        emit CriticalQuorumUpdated(criticalQuorumStake, newQuorum);
        criticalQuorumStake = newQuorum;
    }

    function setMinVoteStake(uint256 newStake) external onlyOwner {
        emit MinVoteStakeUpdated(minVoteStake, newStake);
        minVoteStake = newStake;
    }

    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert NotOwner();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert NotOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    // ------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------

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

        emit ProposalCreated(proposalId, msg.sender, target, title, p.votingEndsAt, p.executeAfter, criticalCalls[target][bytes4(callData)]);
    }

    /// @notice Vote with escrowed QOR. Voting power is the escrowed amount.
    ///         The stake is locked until the proposal reaches a final state.
    function castVote(uint256 proposalId, uint8 choice) external payable {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp >= p.votingEndsAt) revert VotingClosed();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();
        if (choice != CHOICE_FOR && choice != CHOICE_AGAINST && choice != CHOICE_ABSTAIN) revert BadChoice();
        if (msg.value < minVoteStake) revert VoteStakeTooLow();

        hasVoted[proposalId][msg.sender] = true;
        voteStake[proposalId][msg.sender] += msg.value;

        if (choice == CHOICE_FOR) {
            p.forVotes += msg.value;
        } else if (choice == CHOICE_AGAINST) {
            p.againstVotes += msg.value;
        } else {
            p.abstainVotes += msg.value;
        }

        emit VoteCast(proposalId, msg.sender, choice);
    }

    /// @notice Reclaim the QOR escrowed with a vote once the proposal is final.
    function withdrawVoteStake(uint256 proposalId) external nonReentrant {
        uint256 amount = voteStake[proposalId][msg.sender];
        if (amount == 0) revert NoVoteStake();
        ProposalState state = proposals[proposalId].state;
        if (state == ProposalState.None || state == ProposalState.Open) revert VoteStakeLocked();

        voteStake[proposalId][msg.sender] = 0;
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit VoteStakeWithdrawn(proposalId, msg.sender, amount);
    }

    /// @notice Execute a passed proposal after the timelock, or finalize it.
    ///         The allowlist is re-checked at execution (not only at propose):
    ///         revoking a (target, selector) mid-flight blocks the proposal
    ///         instead of letting it run stale authorization (G6).
    function execute(uint256 proposalId, string calldata description) external nonReentrant returns (bytes memory result) {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (!allowedTargets[p.target]) revert TargetNotAllowed();
        if (!allowedCalls[p.target][bytes4(p.callData)]) revert CallNotAllowed();
        if (block.timestamp < p.executeAfter) revert TimelockActive();
        if (keccak256(bytes(description)) != p.descriptionHash) revert DescriptionMismatch();

        uint256 requiredQuorum = criticalCalls[p.target][bytes4(p.callData)] ? criticalQuorumStake : quorumStake;
        bool passed = p.forVotes > p.againstVotes && (p.forVotes + p.againstVotes) >= requiredQuorum;

        if (!passed) {
            p.state = ProposalState.Rejected;
            _payTreasury(PROPOSER_BOND);
            emit ProposalRejected(proposalId);
            return "";
        }

        // State first (CEI): the proposal is marked Executed before the
        // external call, so a re-entered call sees a closed proposal. A
        // failing target flips it to Failed (funds still go to treasury).
        p.state = ProposalState.Executed;
        bool ok;
        (ok, result) = p.target.call(p.callData);
        if (!ok) {
            p.state = ProposalState.Failed;
            _payTreasury(PROPOSER_BOND);
            emit ProposalFailed(proposalId, result);
            return result;
        }

        _refundBond(p.proposer);
        emit ProposalExecuted(proposalId, result);
    }

    /// @notice Guardian veto during the timelock (temporary safety valve).
    function veto(uint256 proposalId) external nonReentrant {
        if (msg.sender != guardian) revert NotGuardian();
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp >= p.executeAfter) revert TimelockOver();

        p.state = ProposalState.Vetoed;
        _payTreasury(PROPOSER_BOND);
        emit ProposalVetoed(proposalId, msg.sender);
    }

    /// @notice Proposer may cancel their own proposal before voting closes.
    function cancel(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (msg.sender != p.proposer && msg.sender != owner) revert NotProposer();
        if (block.timestamp >= p.votingEndsAt) revert VotingClosed();

        p.state = ProposalState.Cancelled;
        _refundBond(p.proposer);
        emit ProposalCancelled(proposalId);
    }

    /// @notice Permissionless expiry of a stale, never-executed proposal.
    function expireProposal(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Open) revert ProposalNotOpen();
        if (block.timestamp < uint256(p.executeAfter) + PROPOSAL_TTL) revert ProposalNotExpired();

        p.state = ProposalState.Expired;
        _payTreasury(PROPOSER_BOND);
        emit ProposalExpired(proposalId);
    }

    // ------------------------------------------------------------------
    // Pull payments (failed pushes never strand funds)
    // ------------------------------------------------------------------

    function withdrawReturn() external nonReentrant {
        uint256 amount = pendingReturns[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingReturns[msg.sender] = 0;
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit ReturnWithdrawn(msg.sender, amount);
    }

    function withdrawTreasuryCredits() external nonReentrant {
        if (msg.sender != treasury) revert NotTreasury();
        uint256 amount = treasuryCredits;
        if (amount == 0) revert NothingToWithdraw();
        treasuryCredits = 0;
        (bool ok,) = treasury.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit TreasuryCreditsWithdrawn(treasury, amount);
    }

    // ------------------------------------------------------------------
    // Internal transfers
    // ------------------------------------------------------------------

    function _refundBond(address to) internal {
        if (to == address(0)) return;
        (bool ok,) = to.call{ value: PROPOSER_BOND }("");
        if (!ok) pendingReturns[to] += PROPOSER_BOND;
    }

    function _payTreasury(uint256 amount) internal {
        if (amount == 0 || treasury == address(0)) return;
        (bool ok,) = treasury.call{ value: amount }("");
        if (!ok) treasuryCredits += amount;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

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

