// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { SweeftVault } from "../src/SweeftVault.sol";
import { SweeftMarketplace } from "../src/SweeftMarketplace.sol";
import { SweeftDisputeBoard } from "../src/SweeftDisputeBoard.sol";
import { SweeftDAO2 } from "../src/SweeftDAO2.sol";

/// @notice Incremental v3 upgrade on the live network: deploys the fee + dispute
///         stack while keeping the existing OracleRegistry (whose ownership is
///         migrated from DAO v1 by an on-chain proposal afterwards).
///         Run: forge script script/DeployV3.s.sol --rpc-url $QORECHAIN_EVM_RPC_URL --broadcast
contract DeployV3Script is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address oracleRegistry = vm.envAddress("SWEEFT_ORACLE_REGISTRY_ADDRESS");
        string memory cosmosChainId = vm.envString("QORECHAIN_CHAIN_ID");
        uint256 feeBps = 200; // 2%

        vm.startBroadcast(deployerKey);

        SweeftVault vault = new SweeftVault(oracleRegistry, cosmosChainId, feeBps, deployer);
        SweeftMarketplace marketplace = new SweeftMarketplace(address(vault));
        vault.setMarketplace(address(marketplace));
        SweeftDisputeBoard board = new SweeftDisputeBoard(address(vault));
        vault.setDisputeBoard(address(board));

        address[] memory targets = new address[](3);
        targets[0] = oracleRegistry;
        targets[1] = address(vault);
        targets[2] = address(board);
        SweeftDAO2 dao = new SweeftDAO2(targets);

        // The deployer is the interim owner of vault and board; hand both to
        // the DAO now (registry stays with DAO v1 until the migration proposal).
        vault.transferOwnership(address(dao));
        board.transferOwnership(address(dao));

        vm.stopBroadcast();

        console.log("=== Sweeft v3 (fees + dispute board + DAO2) ===");
        console.log("SweeftVault:        ", address(vault));
        console.log("SweeftMarketplace:  ", address(marketplace));
        console.log("SweeftDisputeBoard: ", address(board));
        console.log("SweeftDAO2:         ", address(dao));
        console.log("OracleRegistry kept:", oracleRegistry);
        console.log("");
        console.log("Next: update .env (VAULT/MARKETPLACE/DISPUTE_BOARD/DAO2 addresses).");
    }
}
