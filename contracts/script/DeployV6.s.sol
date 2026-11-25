// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SweeftVault} from "../src/SweeftVault.sol";
import {SweeftMarketplace} from "../src/SweeftMarketplace.sol";
import {SweeftDisputeBoard} from "../src/SweeftDisputeBoard.sol";
import {SweeftDAO2} from "../src/SweeftDAO2.sol";
import {SweeftOracleRegistry} from "../src/SweeftOracleRegistry.sol";

/// @notice v6 deployment — residual-review hardening:
///   N-1 dispute only via the board; N-2 proof-based expiry; N-3 random panels,
///   near-value stake, fixed resolver fee from the bond; N-4 sweepable pool;
///   N-5 guardian veto + critical quorum + cancel/expire; N-9 verifier bonds.
///
///   Env: DEPLOYER_PRIVATE_KEY, DEPLOYER_ADDRESS, QORECHAIN_CHAIN_ID
///        SWEEFT_VERIFIER_ADDRESS, SWEEFT_CARRIER_ADDRESS, SWEEFT_TREASURY_ADDRESS (all optional)
contract DeployV6Script is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        string memory cosmosChainId = vm.envString("QORECHAIN_CHAIN_ID");
        address verifier = vm.envOr("SWEEFT_VERIFIER_ADDRESS", address(0));
        address carrier = vm.envOr("SWEEFT_CARRIER_ADDRESS", address(0));
        address treasury = vm.envOr("SWEEFT_TREASURY_ADDRESS", deployer);
        uint256 feeBps = 200;

        vm.startBroadcast(deployerKey);

        SweeftOracleRegistry registry = new SweeftOracleRegistry(deployer);
        if (verifier != address(0)) {
            registry.addVerifier(verifier);
        }

        SweeftVault vault = new SweeftVault(address(registry), cosmosChainId, feeBps, treasury);
        SweeftMarketplace marketplace = new SweeftMarketplace(address(vault));
        vault.setMarketplace(address(marketplace));
        SweeftDisputeBoard board = new SweeftDisputeBoard(address(vault), treasury);
        vault.setDisputeBoard(address(board));

        if (carrier != address(0)) {
            vault.registerCarrier(carrier, "LOG-DEMO-001");
        }

        address[] memory targets = new address[](3);
        targets[0] = address(registry);
        targets[1] = address(vault);
        targets[2] = address(board);
        SweeftDAO2 dao = new SweeftDAO2(targets);
        dao.setTreasury(treasury);

        // Selector allowlist.
        dao.setAllowedCall(address(vault), SweeftVault.setFeeBps.selector, true);
        dao.setAllowedCall(address(vault), SweeftVault.setTreasury.selector, true);
        dao.setAllowedCall(address(vault), SweeftVault.registerCarrier.selector, true);
        dao.setAllowedCall(address(vault), SweeftVault.removeCarrier.selector, true);
        dao.setAllowedCall(address(registry), SweeftOracleRegistry.addVerifier.selector, true);
        dao.setAllowedCall(address(registry), SweeftOracleRegistry.removeVerifier.selector, true);
        dao.setAllowedCall(address(registry), SweeftOracleRegistry.setThreshold.selector, true);
        dao.setAllowedCall(address(registry), SweeftOracleRegistry.slashVerifier.selector, true);
        dao.setAllowedCall(address(registry), SweeftOracleRegistry.setMinVerifierStake.selector, true);
        dao.setAllowedCall(address(board), SweeftDisputeBoard.setMinStake.selector, true);
        dao.setAllowedCall(address(board), SweeftDisputeBoard.setVotingPeriod.selector, true);
        dao.setAllowedCall(address(board), SweeftDisputeBoard.setJoinWindow.selector, true);
        dao.setAllowedCall(address(board), SweeftDisputeBoard.setAppealWindow.selector, true);
        dao.setAllowedCall(address(board), SweeftDisputeBoard.setTreasury.selector, true);

        // Self-governance: allow, and mark critical (higher stake quorum).
        dao.setAllowedTarget(address(dao), true);
        _selfCall(dao, SweeftDAO2.setQuorumStake.selector);
        _selfCall(dao, SweeftDAO2.setCriticalQuorumStake.selector);
        _selfCall(dao, SweeftDAO2.setMinVoteStake.selector);
        _selfCall(dao, SweeftDAO2.setAllowedCall.selector);
        _selfCall(dao, SweeftDAO2.setCriticalCall.selector);
        _selfCall(dao, SweeftDAO2.setAllowedTarget.selector);
        _selfCall(dao, SweeftDAO2.setGuardian.selector);
        _selfCall(dao, SweeftDAO2.setTreasury.selector);

        // Hand the stack to the DAO.
        vault.transferOwnership(address(dao));
        board.transferOwnership(address(dao));
        registry.transferOwnership(address(dao));
        dao.transferOwnership(address(dao));

        vm.stopBroadcast();

        console.log("SweeftOracleRegistry v6:", address(registry));
        console.log("SweeftVault v6:", address(vault));
        console.log("SweeftMarketplace v6:", address(marketplace));
        console.log("SweeftDisputeBoard v6:", address(board));
        console.log("SweeftDAO2 v6:", address(dao));
    }

    function _selfCall(SweeftDAO2 dao, bytes4 selector) internal {
        dao.setAllowedCall(address(dao), selector, true);
        dao.setCriticalCall(address(dao), selector, true);
    }
}
