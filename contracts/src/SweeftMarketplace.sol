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
        uint256 price; // uqor
        uint64 quantity;
        ListingStatus status;
        string metadataUri;
        bytes32 metadataHash; // sha256 of the metadata JSON
        uint64 createdAt;
        uint64 updatedAt;
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

    /// @notice Buy a listing: creates an escrow in the Vault and transfers the
    ///         payment to it. The buyer later funds the escrow from the Vault.
    function purchase(uint256 listingId, uint64 deliveryDeadline) external payable returns (uint256 escrowId) {
        Listing storage listing = listings[listingId];
        if (listing.status != ListingStatus.Active) revert ListingNotActive();
        if (listing.quantity == 0) revert OutOfStock();
        if (msg.value != listing.price) revert WrongPayment();
        if (msg.sender == listing.seller) revert InvalidBuyer();

        listing.quantity -= 1;
        if (listing.quantity == 0) {
            listing.status = ListingStatus.Sold;
        }
        listing.updatedAt = uint64(block.timestamp);

        escrowId = vault.createEscrow{ value: msg.value }(msg.sender, listing.seller, deliveryDeadline, msg.value);
        if (escrowId == 0 && vault.escrowCount() == 0) revert EscrowCreationFailed();

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
