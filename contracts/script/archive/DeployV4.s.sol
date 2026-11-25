// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SweeftVault} from "../src/SweeftVault.sol";
import {SweeftMarketplace} from "../src/SweeftMarketplace.sol";
import {SweeftDisputeBoard} from "../src/SweeftDisputeBoard.sol";
import {SweeftDAO2} from "../src/SweeftDAO2.sol";

contract DeployV4Script is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address oracleRegistry = vm.envAddress("SWEEFT_ORACLE_REGISTRY_ADDRESS");
        string memory cosmosChainId = vm.envString("QORECHAIN_CHAIN_ID");
        uint256 feeBps = 200;

        vm.startBroadcast(deployerKey);
        // keep registry, deploy new vault/market/board/dao
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
        vault.transferOwnership(address(dao));
        board.transferOwnership(address(dao));
        vm.stopBroadcast();

        console.log("SweeftVault v4:", address(vault));
        console.log("SweeftMarketplace v4:", address(marketplace));
        console.log("SweeftDisputeBoard v4:", address(board));
        console.log("SweeftDAO2 v4:", address(dao));
        console.log("Registry kept:", oracleRegistry);
    }
}
