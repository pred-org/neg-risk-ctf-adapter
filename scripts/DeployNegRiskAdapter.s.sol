// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
import {Vault} from "src/Vault.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";

/// @title DeployNegRiskAdapter
/// @notice Script to deploy the NegRiskAdapter contract
/// @author Pred
contract DeployNegRiskAdapter is Script {
    /// @notice Deploys the NegRiskAdapter and related contracts
    /// @param _ctf The ConditionalTokens contract address
    /// @param _collateral The collateral token address (e.g., USDC)
    /// @param _vault The vault address for fee collection
    /// @return adapter The deployed NegRiskAdapter address
    function deploy(address _ctf, address _collateral, address _vault) public returns (address adapter) {
        // Validate inputs
        require(_ctf != address(0), "Invalid CTF address");
        require(_collateral != address(0), "Invalid collateral address");
        require(_vault != address(0), "Invalid vault address");

        console.log("Deploying NegRiskAdapter...");
        console.log("CTF address:", _ctf);
        console.log("Collateral address:", _collateral);
        console.log("Vault address:", _vault);

        vm.startBroadcast();
        
        // Deploy the NegRiskAdapter
        adapter = address(new NegRiskAdapter(_ctf, _collateral, _vault));
        
        vm.stopBroadcast();

        console.log("NegRiskAdapter deployed at:", adapter);

        // Verify the deployment
        NegRiskAdapter adapterContract = NegRiskAdapter(adapter);
        require(address(adapterContract.ctf()) == _ctf, "CTF not set correctly");
        require(address(adapterContract.col()) == _collateral, "Collateral not set correctly");
        require(adapterContract.vault() == _vault, "Vault not set correctly");

        console.log("Deployment verification successful!");
    }

    /// @notice Deploy with addresses from addresses.json for a specific chain
    /// @param chainId The chain ID to deploy on
    function deployForChain(uint256 chainId) public returns (address adapter) {
        // Load addresses from addresses.json
        string memory addressesPath = string(abi.encodePacked("./addresses.json"));
        string memory addressesJson = vm.readFile(addressesPath);
        
        // Parse the JSON to get addresses for the specific chain
        string memory chainKey = vm.toString(chainId);
        string memory ctfKey = string(abi.encodePacked(".", chainKey, ".ctf"));
        string memory usdcKey = string(abi.encodePacked(".", chainKey, ".usdc"));
        string memory vaultKey = string(abi.encodePacked(".", chainKey, ".negRiskVault"));
        
        address ctf = vm.parseJsonAddress(addressesJson, ctfKey);
        address usdc = vm.parseJsonAddress(addressesJson, usdcKey);
        address vault = vm.parseJsonAddress(addressesJson, vaultKey);
        
        console.log("Deploying for chain ID:", chainId);
        return deploy(ctf, usdc, vault);
    }

    /// @notice Deploy for Polygon Mumbai testnet
    function deployMumbai() public returns (address adapter) {
        return deployForChain(80001);
    }

    /// @notice Deploy for Polygon mainnet
    function deployPolygon() public returns (address adapter) {
        return deployForChain(137);
    }

    /// @notice Deploy with custom parameters and save to addresses.json
    /// @param _ctf The ConditionalTokens contract address
    /// @param _collateral The collateral token address
    /// @param _vault The vault address
    /// @param chainId The chain ID to save the address for
    function deployAndSave(address _ctf, address _collateral, address _vault, uint256 chainId) public returns (address adapter) {
        adapter = deploy(_ctf, _collateral, _vault);
        
        // Save the deployed address to addresses.json
        string memory addressesPath = string(abi.encodePacked("./addresses.json"));
        string memory addressesJson = vm.readFile(addressesPath);
        
        string memory chainKey = vm.toString(chainId);
        string memory adapterKey = string(abi.encodePacked(".", chainKey, ".negRiskAdapter"));
        
        // Update the JSON with the new adapter address
        string memory updatedJson = vm.serializeAddress(addressesJson, adapterKey, adapter);
        vm.writeFile(addressesPath, updatedJson);
        
        console.log("Address saved to addresses.json for chain", chainId);
        return adapter;
    }
}
