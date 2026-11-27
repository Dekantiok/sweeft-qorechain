// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SweeftVault} from "../src/SweeftVault.sol";
import {SweeftMarketplace} from "../src/SweeftMarketplace.sol";
import {SweeftDisputeBoard} from "../src/SweeftDisputeBoard.sol";
import {SweeftOracleRegistry} from "../src/SweeftOracleRegistry.sol";

/// @notice Deployment phase 1 (v9): core stack without DAO, WITHOUT verifier
///         registration — `addVerifier` reads the chain PQC precompile, which
///         forge's local simulation cannot reach. Register the verifier with
///         a direct cast send after this script, then run Handover.s.sol.
///         Env: DEPLOYER_PRIVATE_KEY, DEPLOYER_ADDRESS, QORECHAIN_CHAIN_ID,
///         SWEEFT_CARRIER_ADDRESS, SWEEFT_TREASURY_ADDRESS (optional)
contract DeployStackScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        string memory cosmosChainId = vm.envString("QORECHAIN_CHAIN_ID");
        address carrier = vm.envOr("SWEEFT_CARRIER_ADDRESS", address(0));
        address treasury = vm.envOr("SWEEFT_TREASURY_ADDRESS", deployer);

        vm.startBroadcast(deployerKey);

        SweeftOracleRegistry registry = new SweeftOracleRegistry(deployer);

        SweeftVault vault = new SweeftVault(address(registry), cosmosChainId, 200, treasury);
        SweeftMarketplace marketplace = new SweeftMarketplace(address(vault));
        vault.setMarketplace(address(marketplace));
        SweeftDisputeBoard board = new SweeftDisputeBoard(address(vault), treasury);
        vault.setDisputeBoard(address(board));

        if (carrier != address(0)) {
            vault.registerCarrier(carrier, "LOG-DEMO-001");
        }

        vm.stopBroadcast();

        console.log("SweeftOracleRegistry:", address(registry));
        console.log("SweeftVault:", address(vault));
        console.log("SweeftMarketplace:", address(marketplace));
        console.log("SweeftDisputeBoard:", address(board));
    }
}
