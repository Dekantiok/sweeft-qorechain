// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { SweeftVault } from "../src/SweeftVault.sol";
import { SweeftMarketplace } from "../src/SweeftMarketplace.sol";

/// @notice Redeploys the message-format v2 Vault and Marketplace, keeping the
///         existing OracleRegistry (owned by the DAO) and the DAO itself.
///         Run: forge script script/DeployV2.s.sol --rpc-url $QORECHAIN_EVM_RPC_URL --broadcast
contract DeployV2Script is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address oracleRegistry = vm.envAddress("SWEEFT_ORACLE_REGISTRY_ADDRESS");
        string memory cosmosChainId = vm.envString("QORECHAIN_CHAIN_ID");

        vm.startBroadcast(deployerKey);

        SweeftVault vault = new SweeftVault(oracleRegistry, cosmosChainId);
        SweeftMarketplace marketplace = new SweeftMarketplace(address(vault));
        vault.setMarketplace(address(marketplace));

        vm.stopBroadcast();

        console.log("=== Sweeft v2 (QoreSign message format) ===");
        console.log("SweeftVault:        ", address(vault));
        console.log("SweeftMarketplace:  ", address(marketplace));
        console.log("OracleRegistry kept:", oracleRegistry);
        console.log("Deployer:           ", deployer);
        console.log("");
        console.log("Next: update SWEEFT_VAULT_ADDRESS and SWEEFT_MARKETPLACE_ADDRESS in .env");
    }
}
