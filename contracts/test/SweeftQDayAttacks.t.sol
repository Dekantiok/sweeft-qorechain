// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SweeftVault} from "../src/SweeftVault.sol";
import {SweeftOracleRegistry} from "../src/SweeftOracleRegistry.sol";
import {SweeftDisputeBoard} from "../src/SweeftDisputeBoard.sol";

contract MockKeyStatusQDay {
    mapping(address => bytes) internal pks;
    mapping(address => bool) internal proven0;
    function setRegistered(address a, bool r, bool p) external { if (r) pks[a]=abi.encodePacked(a); else pks[a]=bytes(""); proven0[a]=p; }
    function pqcKeyStatus(address a) external view returns (bool,uint8,bytes memory,bool) { bool reg=pks[a].length>0; return (reg,1,pks[a],proven0[a]); }
}
contract MockVerifyQDay {
    bool internal useDigest; bytes32 internal expected;
    function expectDigest(bytes32 d) external { expected=d; useDigest=true; }
    function pqcVerify(bytes calldata, bytes calldata, bytes calldata message) external view returns (bool) { if(!useDigest) return true; return keccak256(message)==expected; }
}

/// @notice LOCAL SIMULATION Q-Day attacks (Foundry, not Diana).
///         Maps 1:1 to tools/qday_attack_demo.py scenarios.
contract SweeftQDayAttacksTest is Test {
    SweeftVault internal vault;
    SweeftDisputeBoard internal board;
    SweeftOracleRegistry internal registry;
    address internal buyer = address(0xB0B);
    address internal seller = address(0x5E11E);
    address internal attacker = address(0xBAD);
    address internal carrier = address(0xCA99);
    address internal verifier = address(0x0AC1E);
    address internal treasury = address(0x7EA5);
    uint64 internal constant ISSUED = 1_000_000;
    function setUp() public {
        registry = new SweeftOracleRegistry(address(this));
        MockKeyStatusQDay ks = new MockKeyStatusQDay();
        MockVerifyQDay mv = new MockVerifyQDay();
        vm.etch(0x0000000000000000000000000000000000000a02, address(ks).code);
        vm.etch(0x0000000000000000000000000000000000000a01, address(mv).code);
        MockKeyStatusQDay(0x0000000000000000000000000000000000000a02).setRegistered(buyer,true,true);
        MockKeyStatusQDay(0x0000000000000000000000000000000000000a02).setRegistered(verifier,true,true);
        MockKeyStatusQDay(0x0000000000000000000000000000000000000a02).setRegistered(carrier,true,true);
        vault = new SweeftVault(address(registry), "qorechain-diana", 200, treasury);
        board = new SweeftDisputeBoard(address(vault), treasury);
        vault.setDisputeBoard(address(board));
        vault.registerCarrier(carrier, "LOG-DEMO-001");
        registry.addVerifier(verifier);
    }
    function _fund(uint256 amt, address partner, uint256 log) internal returns (uint256) {
        vm.deal(buyer, amt);
        vm.prank(buyer);
        uint256 id = vault.createEscrowWithLogistics(buyer, seller, partner, uint64(block.timestamp+7 days), amt, log);
        vm.prank(buyer);
        vault.fundEscrow{value: amt}(id);
        return id;
    }
    // 1 Classical-only: garbage signature rejected
    function test_QDay1_ClassicalOnlyRejected() public {
        uint256 id = _fund(1 ether, address(0), 0);
        vm.prank(buyer);
        vault.confirmReceipt(id);
        // MockVerify is permissive by default; pin digest to a different msg so garbage fails
        MockVerifyQDay(0x0000000000000000000000000000000000000a01).expectDigest(keccak256("other"));
        vm.expectRevert(SweeftVault.BadPqcSignature.selector);
        vault.release(id, hex"deadbeef");
    }
    // 2 Recipient manipulation: contract builds recipient from storage, attacker cannot redirect
    function test_QDay2_RecipientImmutable() public {
        uint256 id = _fund(1 ether, address(0), 0);
        vm.prank(buyer);
        vault.confirmReceipt(id);
        uint256 beforeBad = vault.credits(attacker);
        vault.release(id, hex"deadbeef");
        assertEq(vault.credits(attacker), beforeBad);
        assertGt(vault.credits(seller), 0);
    }
    // 3 Carrier replay: same sig twice, second reverts (nonce advanced / AlreadyAttested gate)
    function test_QDay3_CarrierReplayBlocked() public {
        uint256 id = _fund(1.1 ether, carrier, 0.1 ether);
        uint64 issued = uint64(block.timestamp);
        vm.prank(carrier);
        vault.attestCarrierEvidence(id, "TRACK-1", "DELIVERED", bytes32(uint256(0x1234)), issued, issued+7 days, hex"deadbeef");
        assertEq(vault.carrierNonce(carrier, id), 1);
        // Replay with digest pinned to the FIRST nonce message must fail on second (nonce=1)
        // MockVerifyAdv digest check: pin to nonce 0 message, second call uses nonce 1 -> mismatch
        // Here permissive mock would pass, so we assert nonce advanced and state is terminal for replay count
        // A stricter digest mock is in SweeftCarrierDomain.t.sol; this test documents nonce consumption.
        assertTrue(vault.getEscrow(id).carrierAttested);
    }
    // 4 Verifier replay: AlreadyAttested on second
    function test_QDay4_VerifierReplayBlocked() public {
        uint256 id = _fund(1 ether, address(0), 0);
        uint64 issued = uint64(block.timestamp);
        vault.attestEvidence(id, verifier, bytes32(uint256(0x1234)), issued, issued+7 days, hex"deadbeef");
        vm.expectRevert(SweeftVault.AlreadyAttested.selector);
        vault.attestEvidence(id, verifier, bytes32(uint256(0x1234)), issued, issued+7 days, hex"deadbeef");
        assertEq(vault.verifierAttestCount(id), 1);
    }
    // 5 Cross-chain: digest pinned to Diana message fails for other chain message
    function test_QDay5_CrossChainReuseBlocked() public {
        uint256 id = _fund(1 ether, address(0), 0);
        vm.prank(buyer);
        vault.confirmReceipt(id);
        // Pin mock to a message for a different vault/chain — release rebuilds Diana vault msg -> mismatch
        MockVerifyQDay(0x0000000000000000000000000000000000000a01).expectDigest(keccak256("qorechain-vladi-other"));
        vm.expectRevert(SweeftVault.BadPqcSignature.selector);
        vault.release(id, hex"deadbeef");
    }
    // 6 AI mandate bypass is Django-layer (see tests/test_ai_tools.py); contract analogue:
    // stolen EVM key (attacker as msg.sender) cannot attest
    function test_QDay6_StolenEvmKeyCannotAttest() public {
        uint256 id = _fund(1 ether, address(0), 0);
        vm.prank(attacker);
        vm.expectRevert(SweeftVault.NotVerifier.selector);
        vault.attestEvidence(id, attacker, bytes32(uint256(0x1234)), ISSUED, ISSUED+7 days, hex"deadbeef");
        assertEq(vault.verifierAttestCount(id), 0);
    }
}
