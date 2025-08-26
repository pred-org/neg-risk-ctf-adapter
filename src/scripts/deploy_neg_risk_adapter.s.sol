// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {NegRiskAdapter} from "../NegRiskAdapter.sol";

/// @title DeployNegRiskAdapter
/// @notice Script to deploy the NegRiskAdapter contract
/// @author Polymarket
contract DeployNegRiskAdapter is Script {
    /// @notice Deploys the NegRiskAdapter
    /// @param ctf - The ConditionalTokens address
    /// @param collateral - The collateral token address (e.g., USDC)
    /// @param vault - The vault address
    /// @return adapter - The deployed NegRiskAdapter address
    function deploy(address ctf, address collateral, address vault) public returns (address adapter) {
        vm.startBroadcast();
        
        // Deploy the NegRiskAdapter
        adapter = address(new NegRiskAdapter(ctf, collateral, vault));
        
        vm.stopBroadcast();
        
        console.log("NegRiskAdapter deployed at:", adapter);
        console.log("CTF address:", ctf);
        console.log("Collateral address:", collateral);
        console.log("Vault address:", vault);
    }

    /// @notice Deploy with default addresses for a specific network
    /// @param network - The network identifier (e.g., "137" for Polygon, "80001" for Mumbai)
    function deployWithNetwork(string memory network) public returns (address adapter) {
        // Load addresses from addresses.json
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/addresses.json");
        string memory json = vm.readFile(path);
        
        // Parse the JSON to get addresses for the specified network
        address ctf = vm.parseJsonAddress(json, string.concat(".", network, ".ctf"));
        address collateral = vm.parseJsonAddress(json, string.concat(".", network, ".usdc"));
        address vault = vm.parseJsonAddress(json, string.concat(".", network, ".negRiskVault"));
        
        return deploy(ctf, collateral, vault);
    }

    /// @notice Deploy to Polygon mainnet
    function deployPolygon() public returns (address adapter) {
        return deployWithNetwork("137");
    }

    /// @notice Deploy to Mumbai testnet
    function deployMumbai() public returns (address adapter) {
        return deployWithNetwork("80001");
    }
}
