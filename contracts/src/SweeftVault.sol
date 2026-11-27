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
