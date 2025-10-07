// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {NegRiskOperator} from "src/NegRiskOperator.sol";

/// @title SetOracle
/// @notice Script to set the oracle address in NegRiskOperator
/// @author Polymarket
contract SetOracle is Script {
    /// @notice Sets the oracle address in NegRiskOperator
    /// @param _operator The NegRiskOperator contract address
    /// @param _oracle The oracle address to set
    function setOracle(address _operator, address _oracle) public {
        require(_operator != address(0), "Invalid operator address");
        require(_oracle != address(0), "Invalid oracle address");

        console.log("Setting oracle in NegRiskOperator...");
        console.log("Operator address:", _operator);
        console.log("Oracle address:", _oracle);

        vm.startBroadcast();
        
        NegRiskOperator operator = NegRiskOperator(_operator);
        operator.setOracle(_oracle);
        
        vm.stopBroadcast();

        console.log("Oracle set successfully!");
        console.log("Current oracle address:", operator.oracle());
    }

    /// @notice Set oracle for Base Sepolia using addresses from addresses.json
    function setOracleBaseSepolia() public {
        // Load addresses from addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        address negRiskOperator = vm.parseJsonAddress(addressesJson, ".84532.negRiskOperator");
        address oracle = vm.parseJsonAddress(addressesJson, ".84532.oracle");
        
        console.log("Setting oracle for Base Sepolia...");
        setOracle(negRiskOperator, oracle);
    }

    /// @notice Set oracle with custom addresses
    /// @param _operator The NegRiskOperator contract address
    /// @param _oracle The oracle address to set
    function setOracleCustom(address _operator, address _oracle) public {
        setOracle(_operator, _oracle);
    }
}