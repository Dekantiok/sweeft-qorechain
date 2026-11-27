// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SweeftVault } from "../src/SweeftVault.sol";
import { SweeftDisputeBoard } from "../src/SweeftDisputeBoard.sol";
import { SweeftOracleRegistry } from "../src/SweeftOracleRegistry.sol";

contract MockKeyStatus3 {
    mapping(address => bool) internal registered0;
    mapping(address => bool) internal proven0;
    function setRegistered(address a, bool r, bool p) external {
        registered0[a] = r;
        proven0[a] = p;
    }
    function pqcKeyStatus(address a) external view returns (bool, uint8, bytes memory, bool) {
        // The verifier's chain-registered key is its address (test stand-in).
        bytes memory pk = registered0[a] ? abi.encodePacked(a) : bytes("");
        return (registered0[a], 1, pk, proven0[a]);
    }
}

/// @dev Key-sensitive mock: verifies iff sig == abi.encode(pubkey, message).
///      A signature produced under the wrong PQ key fails it.
contract MockVerifyKey {
    function pqcVerify(bytes calldata pubkey, bytes calldata signature, bytes calldata message)
        external
        pure
        returns (bool)
    {
        return keccak256(signature) == keccak256(abi.encode(pubkey, message));
    }
}

/// @notice Phase 3 suite: verifier attestations require the verifier's
///         ML-DSA-87 signature (relayed submissions allowed). A stolen
///         classical key alone cannot manufacture an attestation.
contract SweeftVerifierPQTest is Test {
    SweeftVault internal vault;
    SweeftOracleRegistry internal registry;

    address internal buyer = address(0xB0B);
    address internal seller = address(0x5E11E);
    address internal verifier = address(0x0AC1E);
    address internal verifier2 = address(0x0B2);
    address internal stranger = address(0xBAD);
    address internal treasury = address(0x7EA5);

    bytes32 internal constant EV = bytes32(uint256(0xABCD));
    uint64 internal constant ISSUED = 1_000_000;

    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        // Registry addVerifier pins algoId=1 from the etched precompile.
        MockKeyStatus3 ks = new MockKeyStatus3();
        MockVerifyKey mv = new MockVerifyKey();
        vm.etch(0x0000000000000000000000000000000000000a02, address(ks).code);
        vm.etch(0x0000000000000000000000000000000000000a01, address(mv).code);
        MockKeyStatus3(0x0000000000000000000000000000000000000a02).setRegistered(buyer, true, true);
        MockKeyStatus3(0x0000000000000000000000000000000000000a02).setRegistered(verifier, true, true);
        MockKeyStatus3(0x0000000000000000000000000000000000000a02).setRegistered(verifier2, true, true);

        vault = new SweeftVault(address(registry), "qorechain-diana", 200, treasury);
        SweeftDisputeBoard board = new SweeftDisputeBoard(address(vault), treasury);
        vault.setDisputeBoard(address(board));
        registry.addVerifier(verifier);
        registry.addVerifier(verifier2);
    }

    function _funded() internal returns (uint256) {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 id = vault.createEscrow(buyer, seller, uint64(block.timestamp + 7 days), 1 ether);
        vm.prank(buyer);
        vault.fundEscrow{value: 1 ether}(id);
        return id;
    }

    // The mock verifies sig == abi.encode(pubkey, message); the "signature"
    // here literally carries that encoding (test-only convention).
    function _sign(address who, uint256 id, bytes32 evidence, bytes memory msg) internal view returns (bytes memory) {
        return abi.encode(abi.encodePacked(who), msg);
    }

    function _msg(address who, uint256 id, bytes32 evidence) internal view returns (bytes memory) {
        return vault.buildVerifierMessage(who, 1, id, evidence, ISSUED, ISSUED + 7 days, vault.verifierNonce(who, id));
    }

    // Valid PQ attestation succeeds from a relayer caller too.
    function test_ValidPQAttestation_Succeeds() public {
        uint256 id = _funded();
        bytes memory msg = _msg(verifier, id, EV);
        bytes memory sig = _sign(verifier, id, EV, msg);
        vm.warp(ISSUED + 1);
        vm.prank(stranger); // relayer submission: msg.sender carries no authority
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, sig);
        assertTrue(vault.getEscrow(id).evidenceAttested);
        assertEq(vault.verifierNonce(verifier, id), 1);
    }

    // EVM-key-only attacker: valid caller, garbage signature -> rejected.
    function test_ClassicalKeyOnly_Submission_Fails() public {
        uint256 id = _funded();
        vm.warp(ISSUED + 1);
        vm.prank(verifier);
        vm.expectRevert(SweeftVault.BadVerifierSignature.selector);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, hex"deadbeef");
        assertFalse(vault.getEscrow(id).evidenceAttested);
        assertEq(vault.verifierNonce(verifier, id), 0);
    }

    // Signature bound to another verifier's key fails under this verifier.
    function test_WrongVerifierKey_Fails() public {
        uint256 id = _funded();
        bytes memory msg = _msg(verifier, id, EV);
        bytes memory wrongKeySig = _sign(verifier2, id, EV, msg); // "signed" by verifier2's key
        vm.warp(ISSUED + 1);
        vm.expectRevert(SweeftVault.BadVerifierSignature.selector);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, wrongKeySig);
    }

    // Unregistered verifier cannot attest even with a self-consistent sig.
    function test_UnregisteredVerifier_Fails() public {
        uint256 id = _funded();
        bytes memory msg = _msg(stranger, id, EV);
        bytes memory sig = _sign(stranger, id, EV, msg);
        vm.warp(ISSUED + 1);
        vm.prank(stranger);
        vm.expectRevert(SweeftVault.NotVerifier.selector);
        vault.attestEvidence(id, stranger, EV, ISSUED, ISSUED + 7 days, sig);
    }

    // Revoked verifier cannot authorize new attestations.
    function test_RevokedVerifier_Fails() public {
        uint256 id = _funded();
        registry.removeVerifier(verifier);
        bytes memory msg = _msg(verifier, id, EV);
        bytes memory sig = _sign(verifier, id, EV, msg);
        vm.warp(ISSUED + 1);
        vm.prank(stranger);
        vm.expectRevert(SweeftVault.NotVerifier.selector);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, sig);
    }

    // Expired attestation rejected; nonce unconsumed.
    function test_ExpiredAttestation_Fails() public {
        uint256 id = _funded();
        bytes memory msg = _msg(verifier, id, EV);
        bytes memory sig = _sign(verifier, id, EV, msg);
        vm.warp(ISSUED + 7 days + 1);
        vm.expectRevert(SweeftVault.StaleAttestation.selector);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, sig);
        assertEq(vault.verifierNonce(verifier, id), 0);
    }

    // Duplicate attestation (same verifier, second evidence) rejected.
    function test_DuplicateAttestation_Fails() public {
        uint256 id = _funded();
        bytes memory msg = _msg(verifier, id, EV);
        bytes memory sig = _sign(verifier, id, EV, msg);
        vm.warp(ISSUED + 1);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, sig);
        bytes memory msg2 = _msg(verifier, id, bytes32(uint256(0x9999)));
        bytes memory sig2 = _sign(verifier, id, bytes32(uint256(0x9999)), msg2);
        vm.expectRevert(SweeftVault.AlreadyAttested.selector);
        vault.attestEvidence(id, verifier, bytes32(uint256(0x9999)), ISSUED, ISSUED + 7 days, sig2);
    }

    // Replayed signature: second use fails (AlreadyAttested — the verifier's
    // slot is consumed; the nonce advanced too, so the sig is doubly stale).
    function test_ReplayedSignature_Fails() public {
        uint256 id = _funded();
        bytes memory msg = _msg(verifier, id, EV);
        bytes memory sig = _sign(verifier, id, EV, msg);
        vm.warp(ISSUED + 1);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, sig);
        vm.expectRevert(SweeftVault.AlreadyAttested.selector);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, sig);
    }

    // Mutations to escrow / evidence / chain / vault / version all fail.
    function test_ModifiedEscrowId_Fails() public {
        uint256 id = _funded();
        bytes memory otherMsg = _msg(verifier, id + 1, EV);
        bytes memory sig = _sign(verifier, id + 1, EV, otherMsg);
        vm.warp(ISSUED + 1);
        vm.expectRevert(SweeftVault.BadVerifierSignature.selector);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, sig);
    }

    function test_ModifiedEvidenceHash_Fails() public {
        uint256 id = _funded();
        bytes memory msg = _msg(verifier, id, bytes32(uint256(0x9999)));
        bytes memory sig = _sign(verifier, id, bytes32(uint256(0x9999)), msg);
        vm.warp(ISSUED + 1);
        vm.expectRevert(SweeftVault.BadVerifierSignature.selector);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, sig);
    }

    function test_WrongChainSignature_Fails() public {
        SweeftVault otherChain = new SweeftVault(address(registry), "qorechain-other", 200, treasury);
        uint256 id = _funded();
        bytes memory foreignMsg = vault.buildVerifierMessage(verifier, 1, id, EV, ISSUED, ISSUED + 7 days, 0);
        // Same visible fields, but the vault input differs: forge a sig over the
        // other deployment's message (vault field differs) against this one.
        assertEq(otherChain.cosmosChainId(), "qorechain-other");
        bytes memory sig = _sign(verifier, id, EV, foreignMsg);
        vm.warp(ISSUED + 1);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, sig);
        assertTrue(vault.getEscrow(id).evidenceAttested); // control passes
        // Wrong-vault construction against a second live escrow fails.
        uint256 id2 = _funded();
        assertEq(id2, 1);
        bytes memory otherVaultMsg = otherChain.buildVerifierMessage(verifier, 1, id2, EV, ISSUED, ISSUED + 7 days, 0);
        bytes memory sig2 = _sign(verifier, id2, EV, otherVaultMsg);
        uint256 id3 = _funded();
        assertEq(id3, 2);
        vm.expectRevert(SweeftVault.BadVerifierSignature.selector);
        vault.attestEvidence(id3, verifier, EV, ISSUED, ISSUED + 7 days, sig2);
    }

    function test_WrongKeyVersionSignature_Fails() public {
        uint256 id = _funded();
        bytes memory v9Msg = vault.buildVerifierMessage(verifier, 9, id, EV, ISSUED, ISSUED + 7 days, 0);
        bytes memory sig = _sign(verifier, id, EV, v9Msg);
        vm.warp(ISSUED + 1);
        vm.expectRevert(SweeftVault.BadVerifierSignature.selector);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, sig);
    }

    // M-of-N: one of two is not enough; the second distinct verifier completes it.
    function test_ThresholdNotReachedThenReached() public {
        registry.setThreshold(2);
        uint256 id = _funded();
        bytes memory msg = _msg(verifier, id, EV);
        vm.warp(ISSUED + 1);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, _sign(verifier, id, EV, msg));
        assertFalse(vault.getEscrow(id).evidenceAttested);

        bytes memory msg2 = _msg(verifier2, id, EV);
        vm.prank(stranger);
        vault.attestEvidence(id, verifier2, EV, ISSUED, ISSUED + 7 days, _sign(verifier2, id, EV, msg2));
        assertTrue(vault.getEscrow(id).evidenceAttested);
    }

    // Same verifier cannot fill both threshold seats (duplicate rejection
    // already covers this: AlreadyAttested before counting twice).
    function test_SameVerifierCannotFillTwoSeats() public {
        registry.setThreshold(2);
        uint256 id = _funded();
        bytes memory msg = _msg(verifier, id, EV);
        vm.warp(ISSUED + 1);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, _sign(verifier, id, EV, msg));
        bytes memory msg2 = _msg(verifier, id, EV);
        vm.prank(stranger);
        vm.expectRevert(SweeftVault.AlreadyAttested.selector);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, _sign(verifier, id, EV, msg2));
        assertEq(vault.getEscrow(id).verifierAttestations, 1);
    }

    // Full compromise scenario: evm key stolen, no PQ key -> total rejection.
    function test_StolenEvmKeyAloneCannotAttest() public {
        uint256 id = _funded();
        vm.warp(ISSUED + 1);
        vm.prank(verifier); // attacker submits from the verifier's account
        vm.expectRevert(SweeftVault.BadVerifierSignature.selector);
        vault.attestEvidence(id, verifier, EV, ISSUED, ISSUED + 7 days, hex"00112233");
        assertFalse(vault.getEscrow(id).evidenceAttested);
        assertEq(vault.verifierNonce(verifier, id), 0);
    }
}
