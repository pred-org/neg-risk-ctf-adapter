// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {RevNegRiskAdapter} from "src/RevNegRiskAdapter.sol";
import {INegRiskAdapter} from "src/interfaces/INegRiskAdapter.sol";

/// @title DeployRevNegRiskAdapter
/// @notice Script to deploy the RevNegRiskAdapter contract
/// @author Polymarket
contract DeployRevNegRiskAdapter is Script {
    /// @notice Deploys the RevNegRiskAdapter contract
    /// @param _ctf The ConditionalTokens contract address
    /// @param _collateral The collateral token address (e.g., USDP)
    /// @param _vault The vault address for fee collection
    /// @param _neg The NegRiskAdapter contract address
    /// @return adapter The deployed RevNegRiskAdapter address
    function deploy(address _ctf, address _collateral, address _vault, address _neg) public returns (address adapter) {
        // Validate inputs
        require(_ctf != address(0), "Invalid CTF address");
        require(_collateral != address(0), "Invalid collateral address");
        require(_vault != address(0), "Invalid vault address");
        require(_neg != address(0), "Invalid NegRiskAdapter address");

        console.log("Deploying RevNegRiskAdapter...");
        console.log("CTF address:", _ctf);
        console.log("Collateral address:", _collateral);
        console.log("Vault address:", _vault);
        console.log("NegRiskAdapter address:", _neg);

        vm.startBroadcast();
        
        // Deploy the RevNegRiskAdapter
        adapter = address(new RevNegRiskAdapter(_ctf, _collateral, _vault, INegRiskAdapter(_neg)));
        
        vm.stopBroadcast();

        console.log("RevNegRiskAdapter deployed at:", adapter);

        // Verify the deployment
        RevNegRiskAdapter adapterContract = RevNegRiskAdapter(adapter);
        require(address(adapterContract.ctf()) == _ctf, "CTF not set correctly");
        require(address(adapterContract.col()) == _collateral, "Collateral not set correctly");
        require(adapterContract.vault() == _vault, "Vault not set correctly");
        require(address(adapterContract.neg()) == _neg, "NegRiskAdapter not set correctly");

        console.log("Deployment verification successful!");
    }

    /// @notice Deploy with addresses from addresses.json for a specific chain
    /// @param chainId The chain ID to deploy on
    function deployForChain(uint256 chainId) public returns (address adapter) {
        // Load addresses from addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        // Parse the JSON to get addresses for the specific chain
        string memory chainKey = vm.toString(chainId);
        
        address ctf = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".ctf")));
        address usdc = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".usdc")));
        address vault = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".negRiskVault")));
        address negRiskAdapter = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".negRiskAdapter")));
        
        console.log("Deploying for chain ID:", chainId);
        return deploy(ctf, usdc, vault, negRiskAdapter);
    }

    /// @notice Deploy for Polygon Mumbai testnet
    function deployMumbai() public returns (address adapter) {
        return deployForChain(80001);
    }

    /// @notice Deploy for Polygon mainnet
    function deployPolygon() public returns (address adapter) {
        return deployForChain(137);
    }

    /// @notice Deploy for Monad testnet
    function deployMonad() public returns (address adapter) {
        return deployForChain(10143);
    }

    /// @notice Deploy with custom parameters and save to addresses.json
    /// @param _ctf The ConditionalTokens contract address
    /// @param _collateral The collateral token address
    /// @param _vault The vault address
    /// @param _neg The NegRiskAdapter contract address
    /// @param chainId The chain ID to save the address for
    function deployAndSave(
        address _ctf,
        address _collateral,
        address _vault,
        address _neg,
        uint256 chainId
    ) public returns (address adapter) {
        adapter = deploy(_ctf, _collateral, _vault, _neg);
        
        // Save the deployed address to addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        string memory chainKey = vm.toString(chainId);
        string memory adapterKey = string(abi.encodePacked(".", chainKey, ".revNegRiskAdapter"));
        
        // Update the JSON with the new adapter address
        string memory updatedJson = vm.serializeAddress(addressesJson, adapterKey, adapter);
        vm.writeFile(addressesPath, updatedJson);
        
        console.log("Address saved to addresses.json for chain", chainId);
        return adapter;
    }
}
