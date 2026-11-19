// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { SweeftOracleRegistry } from "../src/SweeftOracleRegistry.sol";
import { SweeftVault } from "../src/SweeftVault.sol";
import { SweeftMarketplace } from "../src/SweeftMarketplace.sol";
import { SweeftDAO } from "../src/SweeftDAO.sol";

/// @notice Deploys the full Sweeft stack to QoreChain Diana (EVM chain 9800).
/// @dev Order and wiring:
///      1. OracleRegistry (deployer = interim owner)
///      2. Vault(oracleRegistry)
///      3. Marketplace(vault)
///      4. vault.setMarketplace(marketplace)
///      5. DAO(oracleRegistry)
///      6. oracleRegistry.transferOwnership(dao)  <- DAO governs verifiers
///
///      Run:
///        forge script script/Deploy.s.sol --rpc-url diana --broadcast
///      Needs DEPLOYER_PRIVATE_KEY in the environment and an OPEN EVM WINDOW
///      on the deployer account (deploys are EVM-lane transactions).
contract DeployScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        vm.startBroadcast(deployerKey);

        SweeftOracleRegistry oracleRegistry = new SweeftOracleRegistry(deployer);

        SweeftVault vault = new SweeftVault(address(oracleRegistry), "qorechain-diana");

        SweeftMarketplace marketplace = new SweeftMarketplace(address(vault));

        vault.setMarketplace(address(marketplace));

        SweeftDAO dao = new SweeftDAO(address(oracleRegistry));

        oracleRegistry.transferOwnership(address(dao));

        vm.stopBroadcast();

        console.log("=== Sweeft deployment (qorechain-diana) ===");
        console.log("SweeftOracleRegistry:", address(oracleRegistry));
        console.log("SweeftVault:         ", address(vault));
        console.log("SweeftMarketplace:   ", address(marketplace));
        console.log("SweeftDAO:           ", address(dao));
        console.log("");
        console.log("Next: copy these into .env as SWEEFT_*_ADDRESS");
    }
}
