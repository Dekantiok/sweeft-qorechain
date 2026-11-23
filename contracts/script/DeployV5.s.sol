// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SweeftVault} from "../src/SweeftVault.sol";
import {SweeftMarketplace} from "../src/SweeftMarketplace.sol";
import {SweeftDisputeBoard} from "../src/SweeftDisputeBoard.sol";
import {SweeftDAO2} from "../src/SweeftDAO2.sol";
import {SweeftOracleRegistry} from "../src/SweeftOracleRegistry.sol";

/// @notice v5 deployment: hardened governance (bounded periods, selector
///         allowlist, quorum, timelock, bond), threshold oracle, bound carrier
///         attestation, deadline bounds and fee snapshots.
///
///         Env:
///           DEPLOYER_PRIVATE_KEY, DEPLOYER_ADDRESS, QORECHAIN_CHAIN_ID
///           SWEEFT_VERIFIER_ADDRESS (optional) — first oracle verifier
///           SWEEFT_CARRIER_ADDRESS  (optional) — demo logistics carrier
contract DeployV5Script is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        string memory cosmosChainId = vm.envString("QORECHAIN_CHAIN_ID");
        address verifier = vm.envOr("SWEEFT_VERIFIER_ADDRESS", address(0));
        address carrier = vm.envOr("SWEEFT_CARRIER_ADDRESS", address(0));
        uint256 feeBps = 200;

        vm.startBroadcast(deployerKey);

        // Fresh registry so the M-of-N threshold is governed from the start.
        SweeftOracleRegistry registry = new SweeftOracleRegistry(deployer);
        if (verifier != address(0)) {
            registry.addVerifier(verifier);
        }
        // Single-oracle testnet default; raise to 2 once three verifiers exist.

        SweeftVault vault = new SweeftVault(address(registry), cosmosChainId, feeBps, deployer);
        SweeftMarketplace marketplace = new SweeftMarketplace(address(vault));
        vault.setMarketplace(address(marketplace));
        SweeftDisputeBoard board = new SweeftDisputeBoard(address(vault));
        vault.setDisputeBoard(address(board));

        if (carrier != address(0)) {
            vault.registerCarrier(carrier, "LOG-DEMO-001");
        }

        address[] memory targets = new address[](3);
        targets[0] = address(registry);
        targets[1] = address(vault);
        targets[2] = address(board);
        SweeftDAO2 dao = new SweeftDAO2(targets);

        // Selector allowlist — a proposal can only call these exact functions.
        dao.setAllowedCall(address(vault), SweeftVault.setFeeBps.selector, true);
        dao.setAllowedCall(address(vault), SweeftVault.setTreasury.selector, true);
        dao.setAllowedCall(address(vault), SweeftVault.registerCarrier.selector, true);
        dao.setAllowedCall(address(vault), SweeftVault.removeCarrier.selector, true);
        dao.setAllowedCall(address(registry), SweeftOracleRegistry.addVerifier.selector, true);
        dao.setAllowedCall(address(registry), SweeftOracleRegistry.removeVerifier.selector, true);
        dao.setAllowedCall(address(registry), SweeftOracleRegistry.setThreshold.selector, true);
        dao.setAllowedCall(address(board), SweeftDisputeBoard.setMinStake.selector, true);
        dao.setAllowedCall(address(board), SweeftDisputeBoard.setVotingPeriod.selector, true);
        dao.setAllowedCall(address(board), SweeftDisputeBoard.setAppealWindow.selector, true);

        // Self-governance: the DAO can adjust its own parameters via proposals.
        dao.setAllowedTarget(address(dao), true);
        dao.setAllowedCall(address(dao), SweeftDAO2.setQuorum.selector, true);
        dao.setAllowedCall(address(dao), SweeftDAO2.setMinVoterBalance.selector, true);
        dao.setAllowedCall(address(dao), SweeftDAO2.setAllowedCall.selector, true);
        dao.setAllowedCall(address(dao), SweeftDAO2.setAllowedTarget.selector, true);

        // Hand the privileged contracts to the DAO, then the DAO to itself so
        // no deployer EOA retains unilateral control.
        vault.transferOwnership(address(dao));
        board.transferOwnership(address(dao));
        registry.transferOwnership(address(dao));
        dao.transferOwnership(address(dao));

        vm.stopBroadcast();

        console.log("SweeftOracleRegistry v5:", address(registry));
        console.log("SweeftVault v5:", address(vault));
        console.log("SweeftMarketplace v5:", address(marketplace));
        console.log("SweeftDisputeBoard v5:", address(board));
        console.log("SweeftDAO2 v5:", address(dao));
    }
}
