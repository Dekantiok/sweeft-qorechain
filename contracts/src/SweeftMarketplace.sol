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
