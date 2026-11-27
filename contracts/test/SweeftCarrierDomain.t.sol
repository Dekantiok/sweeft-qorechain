// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SweeftVault } from "../src/SweeftVault.sol";
import { SweeftDisputeBoard } from "../src/SweeftDisputeBoard.sol";
import { SweeftOracleRegistry } from "../src/SweeftOracleRegistry.sol";

contract MockKeyStatus2 {
    mapping(address => bool) internal registered;
    mapping(address => bool) internal proven;
    function setRegistered(address a, bool r, bool p) external {
        registered[a] = r;
        proven[a] = p;
    }
    function pqcKeyStatus(address a) external view returns (bool, uint8, bytes memory, bool) {
        return (registered[a], 1, registered[a] ? bytes(hex"aa") : bytes(""), proven[a]);
    }
}

/// @dev Message-sensitive mock: verify passes only when the signed bytes
///      hash to the expected digest (set via expectDigest). Default mode
///      (no digest set) always passes, for the older suites' convenience.
contract MockVerifyDigest {
    bool internal useDigest;
    bytes32 internal expected;
    function expectDigest(bytes32 digest) external {
        expected = digest;
        useDigest = true;
    }
    function pqcVerify(bytes calldata, bytes calldata signature, bytes calldata message)
        external
        view
        returns (bool)
    {
        if (!useDigest) return true;
        return keccak256(message) == expected;
    }
}

/// @notice Phase 2 domain-separation suite: carrier signatures are bound to
///         chain, vault, carrier, escrow, tracking, status, evidence, window
///         and nonce. Every mutation must revert with state unchanged.
contract SweeftCarrierDomainTest is Test {
    SweeftVault internal vault;
    SweeftDisputeBoard internal board;
    SweeftOracleRegistry internal registry;
    MockVerifyDigest internal mv;

    address internal buyer = address(0xB0B);
    address internal seller = address(0x5E11E);
    address internal carrier = address(0xCA99);
    address internal carrier2 = address(0xCA98);
    address internal treasury = address(0x7EA5);

    bytes32 internal constant EV = bytes32(uint256(0x1234));
    uint64 internal constant ISSUED = 1_000_000;

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        vault = new SweeftVault(address(registry), "qorechain-diana", 200, treasury);
        board = new SweeftDisputeBoard(address(vault), treasury);
        vault.setDisputeBoard(address(board));
        vault.registerCarrier(carrier, "LOG-DEMO-001");
        vault.registerCarrier(carrier2, "LOG-DEMO-002");

        MockKeyStatus2 ks = new MockKeyStatus2();
        mv = new MockVerifyDigest();
        vm.etch(0x0000000000000000000000000000000000000a02, address(ks).code);
        vm.etch(0x0000000000000000000000000000000000000a01, address(mv).code);
        MockKeyStatus2(0x0000000000000000000000000000000000000a02).setRegistered(buyer, true, true);
        MockKeyStatus2(0x0000000000000000000000000000000000000a02).setRegistered(carrier, true, true);
        MockKeyStatus2(0x0000000000000000000000000000000000000a02).setRegistered(carrier2, true, true);
    }

    function _funded() internal returns (uint256) {
        vm.deal(buyer, 1.1 ether);
        vm.prank(buyer);
        uint256 id = vault.createEscrowWithLogistics(buyer, seller, carrier, uint64(block.timestamp + 7 days), 1.1 ether, 0.1 ether);
        vm.prank(buyer);
        vault.fundEscrow{value: 1.1 ether}(id);
        return id;
    }

    function _msg(uint256 id, string memory tracking, string memory status) internal view returns (bytes memory) {
        return vault.buildCarrierMessage(carrier, id, tracking, status, EV, ISSUED, ISSUED + 7 days, 0);
    }

    function _attest(uint256 id) internal {
        vm.warp(ISSUED + 1);
        vm.prank(carrier);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
    }

    function _expectValid() internal {
        // NOTE: call through the precompile address — the etched code's
        // storage lives at 0x...0a01, not at the mock instance address.
        MockVerifyDigest(0x0000000000000000000000000000000000000a01).expectDigest(
            keccak256(_msg(0, "DEMO-123", "DELIVERED"))
        );
    }

    // (1) Valid signature succeeds; delivery proof records.
    function test_ValidSignature_Succeeds() public {
        uint256 id = _funded();
        assertEq(id, 0);
        _expectValid();
        _attest(id);
        SweeftVault.Escrow memory e = vault.getEscrow(id);
        assertTrue(e.carrierAttested);
        assertTrue(e.carrierDelivered);
        assertTrue(e.evidenceAttested);
    }

    // (2) Invalid signature (wrong digest) fails, state unchanged.
    function test_InvalidSignature_Fails() public {
        uint256 id = _funded();
        vm.warp(ISSUED + 1);
        MockVerifyDigest(0x0000000000000000000000000000000000000a01).expectDigest(keccak256("wrong"));
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadCarrierSignature.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
        assertFalse(vault.getEscrow(id).carrierAttested);
        assertEq(vault.carrierNonce(carrier, id), 0);
    }

    // (3) A different carrier's signature fails on this carrier's escrow
    //     (caller is still the partner; the signature was built for carrier2).
    function test_SignatureBuiltForAnotherCarrier_Fails() public {
        uint256 id = _funded();
        bytes memory otherCarrierMsg = vault.buildCarrierMessage(carrier2, id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, 0);
        MockVerifyDigest(0x0000000000000000000000000000000000000a01).expectDigest(keccak256(otherCarrierMsg));
        vm.warp(ISSUED + 1);
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadCarrierSignature.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
    }

    // (4) Signature for another escrow fails here.
    function test_SignatureForAnotherEscrow_Fails() public {
        uint256 id = _funded();
        bytes memory otherEscrowMsg = vault.buildCarrierMessage(carrier, id + 1, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, 0);
        MockVerifyDigest(0x0000000000000000000000000000000000000a01).expectDigest(keccak256(otherEscrowMsg));
        vm.warp(ISSUED + 1);
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadCarrierSignature.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
    }

    // (5) Signature for another contract deployment fails here.
    function test_SignatureForAnotherDeployment_Fails() public {
        SweeftVault otherVault = new SweeftVault(address(registry), "qorechain-diana", 200, treasury);
        otherVault.registerCarrier(carrier, "LOG-DEMO-001");
        bytes memory otherVaultMsg = otherVault.buildCarrierMessage(carrier, 0, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, 0);
        uint256 id = _funded();
        MockVerifyDigest(0x0000000000000000000000000000000000000a01).expectDigest(keccak256(otherVaultMsg));
        vm.warp(ISSUED + 1);
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadCarrierSignature.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
    }

    // (6) Signature for another chain ID fails here.
    function test_SignatureForAnotherChain_Fails() public {
        SweeftVault foreignVault = new SweeftVault(address(registry), "qorechain-other", 200, treasury);
        foreignVault.registerCarrier(carrier, "LOG-DEMO-001");
        bytes memory foreignMsg = foreignVault.buildCarrierMessage(carrier, 0, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, 0);
        uint256 id = _funded();
        MockVerifyDigest(0x0000000000000000000000000000000000000a01).expectDigest(keccak256(foreignMsg));
        vm.warp(ISSUED + 1);
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadCarrierSignature.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
    }

    // (7) Expired signature fails (now past expiresAt); nonce unconsumed.
    function test_ExpiredSignature_Fails() public {
        uint256 id = _funded();
        _expectValid();
        vm.warp(ISSUED + 7 days + 1); // past expiresAt
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.StaleAttestation.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
        assertEq(vault.carrierNonce(carrier, id), 0);
        assertFalse(vault.getEscrow(id).carrierAttested);
    }

    // (8) Replay: second submission of the same attestation fails, nonce advanced once only.
    function test_ReplayedSignature_Fails() public {
        uint256 id = _funded();
        _expectValid();
        _attest(id);
        assertEq(vault.carrierNonce(carrier, id), 1);
        // Same message (nonce 0) can never verify again: the chain now rebuilds
        // with nonce 1, so the stranded signature mismatches.
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadCarrierSignature.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
        assertEq(vault.carrierNonce(carrier, id), 1);
    }

    // (9) Modified tracking number fails.
    function test_ModifiedTracking_Fails() public {
        uint256 id = _funded();
        _expectValid(); // signed DEMO-123
        vm.warp(ISSUED + 1);
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadCarrierSignature.selector);
        vault.attestCarrierEvidence(id, "DEMO-999", "DELIVERED", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
    }

    // (10) Modified delivery status fails.
    function test_ModifiedStatus_Fails() public {
        uint256 id = _funded();
        _expectValid();
        vm.warp(ISSUED + 1);
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadCarrierSignature.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "LOST", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
    }

    // (11) Modified evidence hash fails.
    function test_ModifiedEvidenceHash_Fails() public {
        uint256 id = _funded();
        _expectValid();
        vm.warp(ISSUED + 1);
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadCarrierSignature.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", bytes32(uint256(0x9999)), ISSUED, ISSUED + 7 days, hex"deadbeef");
    }

    // (12) Modified nonce (built for future nonce) fails.
    function test_ModifiedNonce_Fails() public {
        uint256 id = _funded();
        bytes memory futureNonceMsg = vault.buildCarrierMessage(carrier, id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, 9);
        MockVerifyDigest(0x0000000000000000000000000000000000000a01).expectDigest(keccak256(futureNonceMsg));
        vm.warp(ISSUED + 1);
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.BadCarrierSignature.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
    }

    // (13) Unauthorized caller (not the partner) cannot submit, state unchanged.
    function test_UnauthorizedCarrierCannotSubmit() public {
        uint256 id = _funded();
        _expectValid();
        vm.warp(ISSUED + 1);
        vm.prank(carrier2); // registered, but not this escrow's partner
        vm.expectRevert(SweeftVault.NotCarrier.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
        assertEq(vault.carrierNonce(carrier, id), 0);
        assertFalse(vault.getEscrow(id).carrierAttested);
    }

    // Removed carriers lose attestation authority (F8 fix).
    function test_RemovedCarrierLosesAttestation() public {
        uint256 id = _funded();
        vault.removeCarrier(carrier);
        _expectValid();
        vm.warp(ISSUED + 1);
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.NotCarrier.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
        assertFalse(vault.getEscrow(id).carrierAttested);
    }

    // Expiry cannot be widened: expiresAt must be issuedAt + MAX_ATTEST_AGE.
    function test_WidenedExpiry_Reverts() public {
        uint256 id = _funded();
        vm.warp(ISSUED + 1);
        vm.prank(carrier);
        vm.expectRevert(SweeftVault.StaleAttestation.selector);
        vault.attestCarrierEvidence(id, "DEMO-123", "DELIVERED", EV, ISSUED, ISSUED + 30 days, hex"deadbeef");
    }
}
