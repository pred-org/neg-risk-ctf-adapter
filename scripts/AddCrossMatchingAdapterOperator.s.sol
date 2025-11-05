// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {NegRiskCtfExchange} from "src/NegRiskCtfExchange.sol";

/// @title AddCrossMatchingAdapterOperator
/// @notice Script to add crossMatchingAdapter as operator to negRiskCtfExchange for chain 84532
/// @author Polymarket
contract AddCrossMatchingAdapterOperator is Script {
    /// @notice Adds crossMatchingAdapter as operator to negRiskCtfExchange
    /// @param _negRiskCtfExchange The NegRiskCtfExchange contract address
    /// @param _crossMatchingAdapter The CrossMatchingAdapter contract address
    function addOperator(address _negRiskCtfExchange, address _crossMatchingAdapter) public {
        // Validate inputs
        require(_negRiskCtfExchange != address(0), "Invalid NegRiskCtfExchange address");
        require(_crossMatchingAdapter != address(0), "Invalid CrossMatchingAdapter address");

        console.log("Adding CrossMatchingAdapter as operator to NegRiskCtfExchange...");
        console.log("NegRiskCtfExchange address:", _negRiskCtfExchange);
        console.log("CrossMatchingAdapter address:", _crossMatchingAdapter);

        vm.startBroadcast();
        
        // Add the CrossMatchingAdapter as operator
        NegRiskCtfExchange(_negRiskCtfExchange).addOperator(_crossMatchingAdapter);
        
        vm.stopBroadcast();

        console.log("CrossMatchingAdapter successfully added as operator!");

        // Verify the operation
        NegRiskCtfExchange exchange = NegRiskCtfExchange(_negRiskCtfExchange);
        require(exchange.isOperator(_crossMatchingAdapter), "CrossMatchingAdapter is not an operator");

        console.log("Verification successful - CrossMatchingAdapter is now an operator");
    }

    /// @notice Add operator with addresses from addresses.json for chain 84532
    function addOperatorForChain84532() public {
        // Load addresses from addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        // Parse the JSON to get addresses for chain 84532
        string memory chainKey = "84532";
        
        address negRiskCtfExchange = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".negRiskCtfExchange")));
        address crossMatchingAdapter = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".crossMatchingAdapter")));
        
        console.log("Adding operator for chain 84532...");
        console.log("NegRiskCtfExchange:", negRiskCtfExchange);
        console.log("CrossMatchingAdapter:", crossMatchingAdapter);
        
        addOperator(negRiskCtfExchange, crossMatchingAdapter);
    }

    /// @notice Add operator with custom parameters
    /// @param _negRiskCtfExchange The NegRiskCtfExchange contract address
    /// @param _crossMatchingAdapter The CrossMatchingAdapter contract address
    function addOperatorCustom(address _negRiskCtfExchange, address _crossMatchingAdapter) public {
        addOperator(_negRiskCtfExchange, _crossMatchingAdapter);
    }

    /// @notice Main run function for the script
    function run() public {
        addOperatorForChain84532();
    }
}
