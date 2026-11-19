// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SweeftVault } from "../src/SweeftVault.sol";
import { SweeftMarketplace } from "../src/SweeftMarketplace.sol";
import { SweeftOracleRegistry } from "../src/SweeftOracleRegistry.sol";

contract SweeftMarketplaceTest is Test {
    SweeftVault internal vault;
    SweeftMarketplace internal market;
    SweeftOracleRegistry internal registry;

    address internal seller = address(0x5E11E);
    address internal buyer = address(0xB0B);
    address internal stranger = address(0xCAFE);

    bytes32 internal constant META_HASH = keccak256("metadata");
    string internal constant META_URI = "https://sweeft.local/metadata/0.json";

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        vault = new SweeftVault(address(registry));
        market = new SweeftMarketplace(address(vault));
        vault.setMarketplace(address(market));
    }

    function _deadline(uint64 offset) internal view returns (uint64) {
        return uint64(block.timestamp + offset);
    }

    // ------------------------------------------------------------------
    // Listing management
    // ------------------------------------------------------------------

    function test_CreateListing() public {
        vm.prank(seller);
        uint256 id = market.createListing(1 ether, 3, META_URI, META_HASH);

        assertEq(id, 0);
        SweeftMarketplace.Listing memory l = market.getListing(id);
        assertEq(l.seller, seller);
        assertEq(l.price, 1 ether);
        assertEq(l.quantity, 3);
        assertEq(uint8(l.status), uint8(SweeftMarketplace.ListingStatus.Active));
        assertEq(l.metadataHash, META_HASH);
    }

    function test_CreateListing_RejectsZeroPrice() public {
        vm.expectRevert(SweeftMarketplace.InvalidPrice.selector);
        market.createListing(0, 1, META_URI, META_HASH);
    }

    function test_CreateListing_RejectsZeroQuantity() public {
        vm.expectRevert(SweeftMarketplace.InvalidQuantity.selector);
        market.createListing(1 ether, 0, META_URI, META_HASH);
    }

    function test_CreateListing_RejectsEmptyHash() public {
        vm.expectRevert(SweeftMarketplace.InvalidMetadata.selector);
        market.createListing(1 ether, 1, META_URI, bytes32(0));
    }

    function test_UpdatePrice_OnlySeller() public {
        vm.prank(seller);
        uint256 id = market.createListing(1 ether, 1, META_URI, META_HASH);

        vm.prank(stranger);
        vm.expectRevert(SweeftMarketplace.NotSeller.selector);
        market.updatePrice(id, 2 ether);

        vm.prank(seller);
        market.updatePrice(id, 2 ether);
        assertEq(market.getListing(id).price, 2 ether);
    }

    function test_UpdateMetadata() public {
        vm.prank(seller);
        uint256 id = market.createListing(1 ether, 1, META_URI, META_HASH);

        bytes32 newHash = keccak256("new");
        vm.prank(seller);
        market.updateListingMetadata(id, "https://sweeft.local/metadata/0.v2.json", newHash);

        assertEq(market.getListing(id).metadataHash, newHash);
    }

    function test_CancelListing() public {
        vm.prank(seller);
        uint256 id = market.createListing(1 ether, 1, META_URI, META_HASH);

        vm.prank(stranger);
        vm.expectRevert(SweeftMarketplace.NotSeller.selector);
        market.cancelListing(id);

        vm.prank(seller);
        market.cancelListing(id);
        assertEq(uint8(market.getListing(id).status), uint8(SweeftMarketplace.ListingStatus.Cancelled));
    }

    // ------------------------------------------------------------------
    // Purchase flow
    // ------------------------------------------------------------------

    function test_Purchase_CreatesEscrowAndForwardsPayment() public {
        vm.prank(seller);
        uint256 listingId = market.createListing(1 ether, 1, META_URI, META_HASH);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 escrowId = market.purchase{ value: 1 ether }(listingId, _deadline(7 days));

        // Escrow created and holds the payment.
        assertEq(vault.escrowCount(), 1);
        SweeftVault.Escrow memory e = vault.getEscrow(escrowId);
        assertEq(e.buyer, buyer);
        assertEq(e.seller, seller);
        assertEq(e.amount, 1 ether);
        assertEq(address(vault).balance, 1 ether);

        // Listing marked sold (quantity reached 0).
        assertEq(uint8(market.getListing(listingId).status), uint8(SweeftMarketplace.ListingStatus.Sold));
    }

    function test_Purchase_DecrementsQuantity() public {
        vm.prank(seller);
        uint256 listingId = market.createListing(1 ether, 2, META_URI, META_HASH);

        vm.deal(buyer, 2 ether);

        vm.prank(buyer);
        market.purchase{ value: 1 ether }(listingId, _deadline(7 days));

        assertEq(market.getListing(listingId).quantity, 1);
        assertEq(uint8(market.getListing(listingId).status), uint8(SweeftMarketplace.ListingStatus.Active));

        vm.prank(buyer);
        market.purchase{ value: 1 ether }(listingId, _deadline(7 days));

        assertEq(market.getListing(listingId).quantity, 0);
        assertEq(uint8(market.getListing(listingId).status), uint8(SweeftMarketplace.ListingStatus.Sold));
    }

    function test_Purchase_RejectsWrongPayment() public {
        vm.prank(seller);
        uint256 listingId = market.createListing(1 ether, 1, META_URI, META_HASH);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(SweeftMarketplace.WrongPayment.selector);
        market.purchase{ value: 0.5 ether }(listingId, _deadline(7 days));
    }

    function test_Purchase_RejectsSeller() public {
        vm.prank(seller);
        uint256 listingId = market.createListing(1 ether, 1, META_URI, META_HASH);

        vm.deal(seller, 1 ether);
        vm.prank(seller);
        vm.expectRevert(SweeftMarketplace.InvalidBuyer.selector);
        market.purchase{ value: 1 ether }(listingId, _deadline(7 days));
    }

    function test_Purchase_RejectsCancelled() public {
        vm.prank(seller);
        uint256 listingId = market.createListing(1 ether, 1, META_URI, META_HASH);
        vm.prank(seller);
        market.cancelListing(listingId);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(SweeftMarketplace.ListingNotActive.selector);
        market.purchase{ value: 1 ether }(listingId, _deadline(7 days));
    }

    function test_Purchase_RejectsSoldOut() public {
        vm.prank(seller);
        uint256 listingId = market.createListing(1 ether, 1, META_URI, META_HASH);

        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        market.purchase{ value: 1 ether }(listingId, _deadline(7 days));

        vm.prank(buyer);
        vm.expectRevert(SweeftMarketplace.ListingNotActive.selector);
        market.purchase{ value: 1 ether }(listingId, _deadline(7 days));
    }

    // ------------------------------------------------------------------
    // Full commerce loop: list -> buy -> confirm -> PQ release
    // ------------------------------------------------------------------

    function test_FullLoop_ListBuyConfirmRelease() public {
        // Griefing-resistant precompile mocks, as in the vault tests.
        _installPqcMocks(buyer);

        vm.prank(seller);
        uint256 listingId = market.createListing(1 ether, 1, META_URI, META_HASH);

        // Buyer purchases -> escrow created and funded in one step.
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        uint256 escrowId = market.purchase{ value: 1 ether }(listingId, _deadline(1 days));

        // Escrow holds the money; buyer confirms receipt.
        assertEq(address(vault).balance, 1 ether);
        vm.prank(buyer);
        vault.confirmReceipt(escrowId);

        // Anyone submits the release; seller receives funds.
        uint256 sellerBefore = seller.balance;
        vm.prank(stranger);
        vault.release(escrowId, hex"c0ffee");

        assertEq(seller.balance, sellerBefore + 1 ether);
        assertEq(address(vault).balance, 0);
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Completed));
    }

    function test_FullLoop_RefundPath() public {
        _installPqcMocks(buyer);

        vm.prank(seller);
        uint256 listingId = market.createListing(1 ether, 1, META_URI, META_HASH);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 escrowId = market.purchase{ value: 1 ether }(listingId, _deadline(1 days));

        // Seller never delivers; after the deadline the buyer refunds.
        vm.warp(block.timestamp + 1 days);
        uint256 buyerBefore = buyer.balance;
        vault.refundAfterDeadline(escrowId, hex"c0ffee");

        assertEq(buyer.balance, buyerBefore + 1 ether);
        assertEq(uint8(vault.getEscrow(escrowId).status), uint8(SweeftVault.EscrowStatus.Refunded));
    }

    // ------------------------------------------------------------------
    // Precompile mocks (etched at the fixed QoreChain addresses)
    // ------------------------------------------------------------------

    function _installPqcMocks(address guardian) internal {
        MockKeyStatus ks = new MockKeyStatus();
        MockVerify mv = new MockVerify();
        vm.etch(address(0x0000000000000000000000000000000000000a02), address(ks).code);
        vm.etch(address(0x0000000000000000000000000000000000000a01), address(mv).code);

        MockKeyStatus(address(0x0000000000000000000000000000000000000a02)).setKey(guardian, true);
        MockVerify(address(0x0000000000000000000000000000000000000a01)).setResult(true);
    }
}

contract MockKeyStatus {
    mapping(address => bool) internal keys;

    function setKey(address account, bool registered) external {
        keys[account] = registered;
    }

    function pqcKeyStatus(address account)
        external
        view
        returns (bool registered, uint8 algorithmId, bytes memory pubkey, bool proven)
    {
        bool ok = keys[account];
        bytes memory pk = ok ? bytes(hex"deadbeef") : bytes("");
        return (ok, uint8(1), pk, ok);
    }
}

contract MockVerify {
    bool internal result;

    function setResult(bool value) external {
        result = value;
    }

    function pqcVerify(bytes calldata, bytes calldata, bytes calldata) external view returns (bool) {
        return result;
    }
}
