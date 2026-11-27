// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SweeftVault} from "../src/SweeftVault.sol";
import {SweeftMarketplace} from "../src/SweeftMarketplace.sol";
import {SweeftDisputeBoard} from "../src/SweeftDisputeBoard.sol";
import {SweeftDAO2} from "../src/SweeftDAO2.sol";
import {SweeftOracleRegistry} from "../src/SweeftOracleRegistry.sol";

/// @notice Deployment phase 2 (v9): deploy DAO2, wire the allowlist, hand the
///         stack to the DAO. Runs AFTER `cast send addVerifier` registered
///         the verifier on-chain (the addVerifier precompile read is not
///         simulatable by forge).
///         Env: DEPLOYER_PRIVATE_KEY, DEPLOYER_ADDRESS,
///         SWEEFT_ORACLE_REGISTRY_ADDRESS, SWEEFT_VAULT_ADDRESS,
///         SWEEFT_MARKETPLACE_ADDRESS, SWEEFT_DISPUTE_BOARD_ADDRESS,
///         SWEEFT_TREASURY_ADDRESS (optional)
contract HandoverScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address registryAddr = vm.envAddress("SWEEFT_ORACLE_REGISTRY_ADDRESS");
        address vaultAddr = vm.envAddress("SWEEFT_VAULT_ADDRESS");
        address boardAddr = vm.envAddress("SWEEFT_DISPUTE_BOARD_ADDRESS");
        address treasury = vm.envOr("SWEEFT_TREASURY_ADDRESS", deployer);

        vm.startBroadcast(deployerKey);

        address[] memory targets = new address[](3);
        targets[0] = registryAddr;
        targets[1] = vaultAddr;
        targets[2] = boardAddr;
        SweeftDAO2 dao = new SweeftDAO2(targets);
        dao.setTreasury(treasury);

        dao.setAllowedCall(vaultAddr, SweeftVault.setFeeBps.selector, true);
        dao.setAllowedCall(vaultAddr, SweeftVault.setTreasury.selector, true);
        dao.setAllowedCall(vaultAddr, SweeftVault.registerCarrier.selector, true);
        dao.setAllowedCall(vaultAddr, SweeftVault.removeCarrier.selector, true);
        dao.setAllowedCall(registryAddr, SweeftOracleRegistry.addVerifier.selector, true);
        dao.setAllowedCall(registryAddr, SweeftOracleRegistry.removeVerifier.selector, true);
        dao.setAllowedCall(registryAddr, SweeftOracleRegistry.rotateKeyVersion.selector, true);
        dao.setAllowedCall(registryAddr, SweeftOracleRegistry.setThreshold.selector, true);
        dao.setAllowedCall(registryAddr, SweeftOracleRegistry.slashVerifier.selector, true);
        dao.setAllowedCall(registryAddr, SweeftOracleRegistry.setMinVerifierStake.selector, true);
        dao.setAllowedCall(boardAddr, SweeftDisputeBoard.setMinStake.selector, true);
        dao.setAllowedCall(boardAddr, SweeftDisputeBoard.setVotingPeriod.selector, true);
        dao.setAllowedCall(boardAddr, SweeftDisputeBoard.setJoinWindow.selector, true);
        dao.setAllowedCall(boardAddr, SweeftDisputeBoard.setAppealWindow.selector, true);
        dao.setAllowedCall(boardAddr, SweeftDisputeBoard.setTreasury.selector, true);

        dao.setAllowedTarget(address(dao), true);
        _selfCall(dao, SweeftDAO2.setQuorumStake.selector);
        _selfCall(dao, SweeftDAO2.setCriticalQuorumStake.selector);
        _selfCall(dao, SweeftDAO2.setMinVoteStake.selector);
        _selfCall(dao, SweeftDAO2.setAllowedCall.selector);
        _selfCall(dao, SweeftDAO2.setCriticalCall.selector);
        _selfCall(dao, SweeftDAO2.setAllowedTarget.selector);
        _selfCall(dao, SweeftDAO2.setGuardian.selector);
        _selfCall(dao, SweeftDAO2.setTreasury.selector);

        SweeftVault(vaultAddr).transferOwnership(address(dao));
        SweeftDisputeBoard(payable(boardAddr)).transferOwnership(address(dao));
        SweeftOracleRegistry(registryAddr).transferOwnership(address(dao));
        dao.transferOwnership(address(dao));

        vm.stopBroadcast();

        console.log("SweeftDAO2:", address(dao));
    }

    function _selfCall(SweeftDAO2 dao, bytes4 selector) internal {
        dao.setAllowedCall(address(dao), selector, true);
        dao.setCriticalCall(address(dao), selector, true);
    }
}
