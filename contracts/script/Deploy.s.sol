// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { SweeftOracleRegistry } from "../src/SweeftOracleRegistry.sol";
import { SweeftVault } from "../src/SweeftVault.sol";
import { SweeftMarketplace } from "../src/SweeftMarketplace.sol";
import { SweeftDisputeBoard } from "../src/SweeftDisputeBoard.sol";
import { SweeftDAO2 } from "../src/SweeftDAO2.sol";

/// @notice Fresh full-stack deployment of the current Sweeft contracts.
/// @dev Order and wiring:
///      1. OracleRegistry (deployer = interim owner)
///      2. Vault(oracleRegistry, chainId, feeBps=200, treasury=deployer)
///      3. Marketplace(vault) + vault.setMarketplace
///      4. DisputeBoard(vault) + vault.setDisputeBoard
///      5. DAO2([registry, vault, board]) — allowlisted governance targets
///      6. Ownership handoff: registry -> DAO2 (interim; vault/board next round)
///
///      Run:
///        forge script script/Deploy.s.sol --rpc-url diana --broadcast
contract DeployScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        string memory cosmosChainId = vm.envString("QORECHAIN_CHAIN_ID");
        uint256 feeBps = 200; // 2%

        vm.startBroadcast(deployerKey);

        SweeftOracleRegistry oracleRegistry = new SweeftOracleRegistry(deployer);
        SweeftVault vault = new SweeftVault(address(oracleRegistry), cosmosChainId, feeBps, deployer);
        SweeftMarketplace marketplace = new SweeftMarketplace(address(vault));
        vault.setMarketplace(address(marketplace));
        SweeftDisputeBoard board = new SweeftDisputeBoard(address(vault));
        vault.setDisputeBoard(address(board));

        address[] memory targets = new address[](3);
        targets[0] = address(oracleRegistry);
        targets[1] = address(vault);
        targets[2] = address(board);
        SweeftDAO2 dao = new SweeftDAO2(targets);

        vm.stopBroadcast();

        console.log("=== Sweeft deployment (qorechain-diana) ===");
        console.log("SweeftOracleRegistry:", address(oracleRegistry));
        console.log("SweeftVault:         ", address(vault));
        console.log("SweeftMarketplace:   ", address(marketplace));
        console.log("SweeftDisputeBoard:  ", address(board));
        console.log("SweeftDAO2:          ", address(dao));
        console.log("");
        console.log("Governance handoff (propose + execute on-chain):");
        console.log("  registry.transferOwnership(dao)");
        console.log("  vault.transferOwnership(dao)");
        console.log("  board.transferOwnership(dao)");
    }
}
