// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SweeftVault } from "../src/SweeftVault.sol";
import { SweeftMarketplace } from "../src/SweeftMarketplace.sol";
import { SweeftOracleRegistry } from "../src/SweeftOracleRegistry.sol";

/// @dev Key-sensitive key-status mock: each account's pubkey is its address,
///      so a signature made under another account's key fails verification.
contract QuoteMockKeyStatus {
    mapping(address => bool) internal keys;
    mapping(address => bool) internal proven;

    function setKey(address account, bool registered, bool isProven) external {
        keys[account] = registered;
        proven[account] = isProven;
    }

    function pqcKeyStatus(address account)
        external
        view
        returns (bool registered, uint8 algorithmId, bytes memory pubkey, bool isProven)
    {
        bool ok = keys[account];
        bytes memory pk = ok ? abi.encodePacked(account) : bytes("");
        return (ok, uint8(1), pk, ok && proven[account]);
    }
}

/// @dev Key-sensitive verify mock: verifies iff sig == abi.encode(pubkey, message).
///      A signature produced for a different buyer / price / nonce fails it.
contract QuoteMockVerify {
    function pqcVerify(bytes calldata pubkey, bytes calldata signature, bytes calldata message)
        external
        pure
        returns (bool)
    {
        return keccak256(signature) == keccak256(abi.encode(pubkey, message));
    }
}

/// @notice Phase 3 suite: seller-agent signed quotes for SweeftMarketplace.
contract SweeftMarketplaceQuotesTest is Test {
    SweeftVault internal vault;
    SweeftMarketplace internal market;
    SweeftOracleRegistry internal registry;

    address internal seller = address(0x5E11E);
    address internal buyer = address(0xB0B);
    address internal stranger = address(0xCAFE);
    address internal unregisteredSeller = address(0xBAD5);

    bytes32 internal constant META_HASH = keccak256("metadata");
    string internal constant META_URI = "https://sweeft.local/metadata/0.json";

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        vault = new SweeftVault(address(registry), "qorechain-diana", 200, address(0x7EA5));
        market = new SweeftMarketplace(address(vault));
        vault.setMarketplace(address(market));

        _installPqcMocks();
        QuoteMockKeyStatus ks = QuoteMockKeyStatus(0x0000000000000000000000000000000000000a02);
        ks.setKey(buyer, true, true);
        ks.setKey(seller, true, true);
    }

    function _deadline(uint64 offset) internal view returns (uint64) {
        return uint64(block.timestamp + offset);
    }

    function _expires(uint64 offset) internal view returns (uint64) {
        return uint64(block.timestamp + offset);
    }

    /// @dev Sign `payload` with `who`'s registered PQ key (test-only convention:
    ///      the "signature" literally carries abi.encode(pubkey, message)).
    function _sign(address who, bytes memory payload) internal view returns (bytes memory) {
        (, , bytes memory pk, ) =
            QuoteMockKeyStatus(0x0000000000000000000000000000000000000a02).pqcKeyStatus(who);
        return abi.encode(pk, payload);
    }

    function _quoteSig(address who, uint256 listingId, address forBuyer, uint256 price, uint64 expiresAt)
        internal
        view
        returns (bytes memory)
    {
        uint256 nonce = market.quoteNonce(listingId, forBuyer);
        bytes memory payload = market.buildQuoteMessage(listingId, forBuyer, price, expiresAt, nonce);
        return _sign(who, payload);
    }

    function _createListing(uint256 price, uint64 quantity) internal returns (uint256) {
        vm.prank(seller);
        return market.createListing(price, quantity, META_URI, META_HASH);
    }

    // ------------------------------------------------------------------
    // Quote message format
    // ------------------------------------------------------------------

    function test_BuildQuoteMessage_Format() public {
        uint256 listingId = _createListing(1 ether, 1);
        uint64 expiresAt = _expires(1 days);

        bytes memory payload = market.buildQuoteMessage(listingId, buyer, 0.9 ether, expiresAt, 0);

        // Full signed payload: QoreChain prefix (chain via vault) + inner.
        string memory expected = string.concat(
            "qorechain-msg-v1|qorechain-diana|",
            "sweeft-quote-v1|marketplace=",
            _hex(address(market)),
            "|listing=0|seller=",
            _hex(seller),
            "|buyer=",
            _hex(buyer),
            "|price=900000000000000000|expires=",
            _dec(uint256(expiresAt)),
            "|nonce=0"
        );
        assertEq(string(payload), expected);
    }

    // ------------------------------------------------------------------
    // purchaseWithQuote
    // ------------------------------------------------------------------

    function test_PurchaseWithQuote_Valid() public {
        uint256 listingId = _createListing(1 ether, 1);
        uint256 quotePrice = 0.9 ether; // seller discount below asking
        uint64 expiresAt = _expires(1 days);
        bytes memory sig = _quoteSig(seller, listingId, buyer, quotePrice, expiresAt);

        vm.deal(buyer, quotePrice);
        vm.prank(buyer);
        uint256 escrowId =
            market.purchaseWithQuote{ value: quotePrice }(listingId, _deadline(7 days), quotePrice, expiresAt, sig);

        SweeftVault.Escrow memory e = vault.getEscrow(escrowId);
        assertEq(e.buyer, buyer);
        assertEq(e.seller, seller);
        assertEq(e.amount, quotePrice);
        assertEq(address(vault).balance, quotePrice);
        assertEq(market.quoteNonce(listingId, buyer), 1);
        assertEq(uint8(market.getListing(listingId).status), uint8(SweeftMarketplace.ListingStatus.Sold));
    }

    function test_PurchaseWithQuote_WrongBuyerSignature() public {
        uint256 listingId = _createListing(1 ether, 2);
        uint256 quotePrice = 1 ether;
        uint64 expiresAt = _expires(1 days);
        // Quote was issued for `stranger`, not for the caller `buyer`.
        bytes memory sig = _quoteSig(seller, listingId, stranger, quotePrice, expiresAt);

        vm.deal(buyer, quotePrice);
        vm.prank(buyer);
        vm.expectRevert(SweeftMarketplace.BadQuoteSignature.selector);
        market.purchaseWithQuote{ value: quotePrice }(listingId, _deadline(7 days), quotePrice, expiresAt, sig);
        assertEq(market.quoteNonce(listingId, buyer), 0);
    }

    function test_PurchaseWithQuote_WrongSignerKey() public {
        uint256 listingId = _createListing(1 ether, 1);
        uint256 quotePrice = 1 ether;
        uint64 expiresAt = _expires(1 days);
        // Payload names the buyer, but it was "signed" with the stranger's key.
        bytes memory sig = _quoteSig(stranger, listingId, buyer, quotePrice, expiresAt);

        vm.deal(buyer, quotePrice);
        vm.prank(buyer);
        vm.expectRevert(SweeftMarketplace.BadQuoteSignature.selector);
        market.purchaseWithQuote{ value: quotePrice }(listingId, _deadline(7 days), quotePrice, expiresAt, sig);
    }

    function test_PurchaseWithQuote_Expired() public {
        uint256 listingId = _createListing(1 ether, 1);
        uint256 quotePrice = 1 ether;
        uint64 expiresAt = _expires(1 days);
        bytes memory sig = _quoteSig(seller, listingId, buyer, quotePrice, expiresAt);

        vm.warp(block.timestamp + 1 days); // now == expiresAt, no longer valid
        vm.deal(buyer, quotePrice);
        vm.prank(buyer);
        vm.expectRevert(SweeftMarketplace.QuoteExpired.selector);
        market.purchaseWithQuote{ value: quotePrice }(listingId, _deadline(7 days), quotePrice, expiresAt, sig);
        assertEq(market.quoteNonce(listingId, buyer), 0);
    }

    function test_PurchaseWithQuote_ReplayedNonce() public {
        uint256 listingId = _createListing(1 ether, 2);
        uint256 quotePrice = 1 ether;
        uint64 expiresAt = _expires(1 days);
        bytes memory sig = _quoteSig(seller, listingId, buyer, quotePrice, expiresAt);

        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        market.purchaseWithQuote{ value: quotePrice }(listingId, _deadline(7 days), quotePrice, expiresAt, sig);
        assertEq(market.quoteNonce(listingId, buyer), 1);

        // Same signature again: its nonce (0) is spent.
        vm.prank(buyer);
        vm.expectRevert(SweeftMarketplace.QuoteReplayed.selector);
        market.purchaseWithQuote{ value: quotePrice }(listingId, _deadline(7 days), quotePrice, expiresAt, sig);

        // A fresh quote at the new nonce still works.
        bytes memory sig2 = _quoteSig(seller, listingId, buyer, quotePrice, expiresAt);
        vm.prank(buyer);
        market.purchaseWithQuote{ value: quotePrice }(listingId, _deadline(7 days), quotePrice, expiresAt, sig2);
        assertEq(market.quoteNonce(listingId, buyer), 2);
    }

    function test_PurchaseWithQuote_PriceAboveAsking() public {
        uint256 listingId = _createListing(1 ether, 1);
        uint256 quotePrice = 1.1 ether;
        uint64 expiresAt = _expires(1 days);
        bytes memory sig = _quoteSig(seller, listingId, buyer, quotePrice, expiresAt);

        vm.deal(buyer, quotePrice);
        vm.prank(buyer);
        vm.expectRevert(SweeftMarketplace.PriceAboveMax.selector);
        market.purchaseWithQuote{ value: quotePrice }(listingId, _deadline(7 days), quotePrice, expiresAt, sig);
        assertEq(market.quoteNonce(listingId, buyer), 0);
    }

    function test_PurchaseWithQuote_UnregisteredSellerKey() public {
        vm.prank(unregisteredSeller);
        uint256 listingId = market.createListing(1 ether, 1, META_URI, META_HASH);

        uint256 quotePrice = 1 ether;
        uint64 expiresAt = _expires(1 days);
        // Even a self-consistent signature cannot help: no registered key.
        bytes memory sig = _quoteSig(unregisteredSeller, listingId, buyer, quotePrice, expiresAt);

        vm.deal(buyer, quotePrice);
        vm.prank(buyer);
        vm.expectRevert(SweeftMarketplace.SellerKeyNotRegistered.selector);
        market.purchaseWithQuote{ value: quotePrice }(listingId, _deadline(7 days), quotePrice, expiresAt, sig);
    }

    function test_PurchaseWithQuote_GarbageSignature() public {
        uint256 listingId = _createListing(1 ether, 1);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(SweeftMarketplace.BadQuoteSignature.selector);
        market.purchaseWithQuote{ value: 1 ether }(
            listingId, _deadline(7 days), 1 ether, _expires(1 days), hex"deadbeef"
        );
        assertEq(market.quoteNonce(listingId, buyer), 0);
    }

    // ------------------------------------------------------------------
    // Helpers + precompile mocks (etched at the fixed QoreChain addresses)
    // ------------------------------------------------------------------

    function _hex(address a) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes20 data = bytes20(a);
        bytes memory out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            out[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            out[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(out);
    }

    function _dec(uint256 value) internal pure returns (string memory) {
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

    function _installPqcMocks() internal {
        QuoteMockKeyStatus ks = new QuoteMockKeyStatus();
        QuoteMockVerify mv = new QuoteMockVerify();
        vm.etch(address(0x0000000000000000000000000000000000000a02), address(ks).code);
        vm.etch(address(0x0000000000000000000000000000000000000a01), address(mv).code);
    }
}
