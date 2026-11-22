// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SweeftDisputeBoard} from "../src/SweeftDisputeBoard.sol";
import {SweeftDAO2} from "../src/SweeftDAO2.sol";
import {SweeftVault} from "../src/SweeftVault.sol";

contract DeployV4RestScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address vaultAddr = vm.envAddress("SWEEFT_VAULT_ADDRESS");
        address registry = vm.envAddress("SWEEFT_ORACLE_REGISTRY_ADDRESS");
        vm.startBroadcast(deployerKey);
        SweeftDisputeBoard board = new SweeftDisputeBoard(vaultAddr);
        SweeftVault(vaultAddr).setDisputeBoard(address(board));
        address[] memory targets = new address[](3);
        targets[0] = registry;
        targets[1] = vaultAddr;
        targets[2] = address(board);
        SweeftDAO2 dao = new SweeftDAO2(targets);
        SweeftVault(vaultAddr).transferOwnership(address(dao));
        board.transferOwnership(address(dao));
        vm.stopBroadcast();
        console.log("Board:", address(board));
        console.log("DAO2:", address(dao));
    }
}
