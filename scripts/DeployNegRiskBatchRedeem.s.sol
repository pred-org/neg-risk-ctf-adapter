// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {NegRiskBatchRedeem} from "src/NegRiskBatchRedeem.sol";

/// @title DeployNegRiskBatchRedeem
/// @notice Script to deploy the NegRiskBatchRedeem contract
/// @author Polymarket
contract DeployNegRiskBatchRedeem is Script {
    /// @notice Deploys the NegRiskBatchRedeem contract
    /// @param _negRiskAdapter The NegRiskAdapter contract address
    /// @return batchRedeem The deployed NegRiskBatchRedeem address
    function deploy(address _negRiskAdapter) public returns (address batchRedeem) {
        // Validate inputs
        require(_negRiskAdapter != address(0), "Invalid NegRiskAdapter address");

        console.log("Deploying NegRiskBatchRedeem...");
        console.log("NegRiskAdapter address:", _negRiskAdapter);

        vm.startBroadcast();
        
        // Deploy the NegRiskBatchRedeem
        batchRedeem = address(new NegRiskBatchRedeem(_negRiskAdapter));
        
        vm.stopBroadcast();

        console.log("NegRiskBatchRedeem deployed at:", batchRedeem);

        // Verify the deployment
        NegRiskBatchRedeem batchRedeemContract = NegRiskBatchRedeem(batchRedeem);
        require(address(batchRedeemContract.negRiskAdapter()) == _negRiskAdapter, "NegRiskAdapter not set correctly");

        console.log("Deployment verification successful!");
    }

    /// @notice Deploy with addresses from addresses.json for a specific chain
    /// @param chainId The chain ID to deploy on
    function deployForChain(uint256 chainId) public returns (address batchRedeem) {
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
    function deployMumbai() public returns (address batchRedeem) {
        return deployForChain(80001);
    }

    /// @notice Deploy for Polygon mainnet
    function deployPolygon() public returns (address batchRedeem) {
        return deployForChain(137);
    }

    /// @notice Deploy for Monad testnet
    function deployMonad() public returns (address batchRedeem) {
        return deployForChain(10143);
    }

    /// @notice Deploy for Base Sepolia testnet
    function deployBaseSepolia() public returns (address batchRedeem) {
        return deployForChain(84532);
    }

    /// @notice Deploy with custom parameters and save to addresses.json
    /// @param _negRiskAdapter The NegRiskAdapter contract address
    /// @param chainId The chain ID to save the address for
    function deployAndSave(
        address _negRiskAdapter,
        uint256 chainId
    ) public returns (address batchRedeem) {
        batchRedeem = deploy(_negRiskAdapter);
        
        // Save the deployed address to addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        string memory chainKey = vm.toString(chainId);
        string memory batchRedeemKey = string(abi.encodePacked(".", chainKey, ".negRiskBatchRedeem"));
        
        // Update the JSON with the new batch redeem address
        string memory updatedJson = vm.serializeAddress(addressesJson, batchRedeemKey, batchRedeem);
        vm.writeFile(addressesPath, updatedJson);
        
        console.log("Address saved to addresses.json for chain", chainId);
        return batchRedeem;
    }
}
