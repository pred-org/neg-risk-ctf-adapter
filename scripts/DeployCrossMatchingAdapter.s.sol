// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {CrossMatchingAdapter} from "src/CrossMatchingAdapter.sol";
import {INegRiskAdapter} from "src/interfaces/INegRiskAdapter.sol";
import {IRevNegRiskAdapter} from "src/interfaces/IRevNegRiskAdapter.sol";
import {ICTFExchange} from "src/interfaces/ICTFExchange.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {NegRiskOperator} from "src/NegRiskOperator.sol";

/// @title DeployCrossMatchingAdapter
/// @notice Script to deploy the CrossMatchingAdapter contract
/// @author Pred
contract DeployCrossMatchingAdapter is Script {
    /// @notice Deploys the CrossMatchingAdapter contract
    /// @param _negOperator The NegRiskOperator contract address
    /// @param _ctfExchange The CTFExchange contract address (NegRiskCtfExchange)
    /// @param _revNeg The RevNegRiskAdapter contract address
    /// @return adapter The deployed CrossMatchingAdapter address
    function deploy(address _negOperator, address _ctfExchange, address _revNeg) public returns (address adapter) {
        // Validate inputs
        require(_negOperator != address(0), "Invalid NegRiskOperator address");
        require(_ctfExchange != address(0), "Invalid CTFExchange address");
        require(_revNeg != address(0), "Invalid RevNegRiskAdapter address");

        console.log("Deploying CrossMatchingAdapter...");
        console.log("NegRiskOperator address:", _negOperator);
        console.log("CTFExchange address:", _ctfExchange);
        console.log("RevNegRiskAdapter address:", _revNeg);

        vm.startBroadcast();
        
        // Deploy the CrossMatchingAdapter
        adapter = address(new CrossMatchingAdapter(
            NegRiskOperator(_negOperator),
            ICTFExchange(_ctfExchange),
            IRevNegRiskAdapter(_revNeg)
        ));
        
        vm.stopBroadcast();

        console.log("CrossMatchingAdapter deployed at:", adapter);

        // Verify the deployment
        CrossMatchingAdapter adapterContract = CrossMatchingAdapter(adapter);
        require(address(adapterContract.negOperator()) == _negOperator, "NegRiskOperator not set correctly");
        require(address(adapterContract.ctfExchange()) == _ctfExchange, "CTFExchange not set correctly");
        require(address(adapterContract.revNeg()) == _revNeg, "RevNegRiskAdapter not set correctly");

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
        
        address negRiskOperator = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".negRiskOperator")));
        address negRiskCtfExchange = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".negRiskCtfExchange")));
        address revNegRiskAdapter = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".revNegRiskAdapter")));
        
        console.log("Deploying for chain ID:", chainId);
        return deploy(negRiskOperator, negRiskCtfExchange, revNegRiskAdapter);
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
    /// @param _negOperator The NegRiskOperator contract address
    /// @param _ctfExchange The CTFExchange contract address
    /// @param _revNeg The RevNegRiskAdapter contract address
    /// @param chainId The chain ID to save the address for
    function deployAndSave(
        address _negOperator,
        address _ctfExchange,
        address _revNeg,
        uint256 chainId
    ) public returns (address adapter) {
        adapter = deploy(_negOperator, _ctfExchange, _revNeg);
        
        // Save the deployed address to addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        string memory chainKey = vm.toString(chainId);
        string memory adapterKey = string(abi.encodePacked(".", chainKey, ".crossMatchingAdapter"));
        
        // Update the JSON with the new adapter address
        string memory updatedJson = vm.serializeAddress(addressesJson, adapterKey, adapter);
        vm.writeFile(addressesPath, updatedJson);
        
        console.log("Address saved to addresses.json for chain", chainId);
        return adapter;
    }
}
