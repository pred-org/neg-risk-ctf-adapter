// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {NegRiskOperator} from "src/NegRiskOperator.sol";

/// @title DeployNegRiskOperator
/// @notice Script to deploy the NegRiskOperator contract
/// @author Polymarket
contract DeployNegRiskOperator is Script {
    /// @notice Deploys the NegRiskOperator contract
    /// @param _nrAdapter The NegRiskAdapter contract address
    /// @return operator The deployed NegRiskOperator address
    function deploy(address _nrAdapter) public returns (address operator) {
        // Validate inputs
        require(_nrAdapter != address(0), "Invalid NegRiskAdapter address");

        console.log("Deploying NegRiskOperator...");
        console.log("NegRiskAdapter address:", _nrAdapter);

        vm.startBroadcast();
        
        // Deploy the NegRiskOperator
        operator = address(new NegRiskOperator(_nrAdapter));
        
        vm.stopBroadcast();

        console.log("NegRiskOperator deployed at:", operator);

        // Verify the deployment
        NegRiskOperator operatorContract = NegRiskOperator(operator);
        require(address(operatorContract.nrAdapter()) == _nrAdapter, "NegRiskAdapter not set correctly");

        console.log("Deployment verification successful!");
    }

    /// @notice Deploy with addresses from addresses.json for a specific chain
    /// @param chainId The chain ID to deploy on
    function deployForChain(uint256 chainId) public returns (address operator) {
        // Load addresses from addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        // Parse the JSON to get addresses for the specific chain
        string memory chainKey = vm.toString(chainId);
        
        address negRiskAdapter = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".negRiskAdapter")));
        
        console.log("Deploying for chain ID:", chainId);
        return deploy(negRiskAdapter);
    }

    /// @notice Deploy for Polygon Mumbai testnet
    function deployMumbai() public returns (address operator) {
        return deployForChain(80001);
    }

    /// @notice Deploy for Polygon mainnet
    function deployPolygon() public returns (address operator) {
        return deployForChain(137);
    }

    /// @notice Deploy for Monad testnet
    function deployMonad() public returns (address operator) {
        return deployForChain(10143);
    }

    /// @notice Deploy with custom parameters and save to addresses.json
    /// @param _nrAdapter The NegRiskAdapter contract address
    /// @param chainId The chain ID to save the address for
    function deployAndSave(
        address _nrAdapter,
        uint256 chainId
    ) public returns (address operator) {
        operator = deploy(_nrAdapter);
        
        // Save the deployed address to addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        string memory chainKey = vm.toString(chainId);
        string memory operatorKey = string(abi.encodePacked(".", chainKey, ".negRiskOperator"));
        
        // Update the JSON with the new operator address
        string memory updatedJson = vm.serializeAddress(addressesJson, operatorKey, operator);
        vm.writeFile(addressesPath, updatedJson);
        
        console.log("Address saved to addresses.json for chain", chainId);
        return operator;
    }
}
