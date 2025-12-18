// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {CtfExchangeBatchRedeem} from "src/CtfExchangeBatchRedeem.sol";

/// @title DeployCtfExchangeBatchRedeem
/// @notice Script to deploy the CtfExchangeBatchRedeem contract
/// @author Pred
contract DeployCtfExchangeBatchRedeem is Script {
    /// @notice Deploys the CtfExchangeBatchRedeem contract
    /// @param _ctf The ConditionalTokens contract address
    /// @param _collateral The collateral token address (e.g., USDC)
    /// @return batchRedeem The deployed CtfExchangeBatchRedeem address
    function deploy(address _ctf, address _collateral) public returns (address batchRedeem) {
        // Validate inputs
        require(_ctf != address(0), "Invalid CTF address");
        require(_collateral != address(0), "Invalid collateral address");

        console.log("Deploying CtfExchangeBatchRedeem...");
        console.log("CTF address:", _ctf);
        console.log("Collateral address:", _collateral);

        vm.startBroadcast();
        
        // Deploy the CtfExchangeBatchRedeem
        batchRedeem = address(new CtfExchangeBatchRedeem(_ctf, _collateral));
        
        vm.stopBroadcast();

        console.log("CtfExchangeBatchRedeem deployed at:", batchRedeem);

        // Verify the deployment
        CtfExchangeBatchRedeem batchRedeemContract = CtfExchangeBatchRedeem(batchRedeem);
        require(address(batchRedeemContract.ctf()) == _ctf, "CTF not set correctly");
        require(address(batchRedeemContract.col()) == _collateral, "Collateral not set correctly");

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
        string memory ctfKey = string(abi.encodePacked(".", chainKey, ".ctf"));
        string memory usdcKey = string(abi.encodePacked(".", chainKey, ".usdc"));
        
        address ctf = vm.parseJsonAddress(addressesJson, ctfKey);
        address usdc = vm.parseJsonAddress(addressesJson, usdcKey);
        
        console.log("Deploying for chain ID:", chainId);
        return deploy(ctf, usdc);
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
    /// @param _ctf The ConditionalTokens contract address
    /// @param _collateral The collateral token address
    /// @param chainId The chain ID to save the address for
    function deployAndSave(
        address _ctf,
        address _collateral,
        uint256 chainId
    ) public returns (address batchRedeem) {
        batchRedeem = deploy(_ctf, _collateral);
        
        // Save the deployed address to addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        string memory chainKey = vm.toString(chainId);
        string memory batchRedeemKey = string(abi.encodePacked(".", chainKey, ".ctfExchangeBatchRedeem"));
        
        // Update the JSON with the new batch redeem address
        string memory updatedJson = vm.serializeAddress(addressesJson, batchRedeemKey, batchRedeem);
        vm.writeFile(addressesPath, updatedJson);
        
        console.log("Address saved to addresses.json for chain", chainId);
        return batchRedeem;
    }
}

