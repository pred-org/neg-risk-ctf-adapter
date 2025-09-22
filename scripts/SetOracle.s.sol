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
    /// @param operatorAddress The NegRiskOperator contract address
    /// @param oracleAddress The oracle address to set
    function setOracle(address operatorAddress, address oracleAddress) public {
        require(operatorAddress != address(0), "Invalid operator address");
        require(oracleAddress != address(0), "Invalid oracle address");

        console.log("Setting oracle address...");
        console.log("NegRiskOperator address:", operatorAddress);
        console.log("Oracle address:", oracleAddress);

        vm.startBroadcast();
        
        NegRiskOperator operator = NegRiskOperator(operatorAddress);
        operator.setOracle(oracleAddress);
        
        vm.stopBroadcast();

        console.log("Oracle address set successfully!");
        
        // Verify the oracle was set correctly
        address currentOracle = operator.oracle();
        require(currentOracle == oracleAddress, "Oracle not set correctly");
        console.log("Verification successful! Current oracle:", currentOracle);
    }

    /// @notice Set oracle for Monad testnet using addresses from addresses.json
    function setOracleMonad(address oracleAddress) public {
        // Load addresses from addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        // Get the NegRiskOperator address for Monad testnet
        address operatorAddress = vm.parseJsonAddress(addressesJson, ".10143.negRiskOperator");
        
        console.log("Setting oracle for Monad testnet...");
        return setOracle(operatorAddress, oracleAddress);
    }
}
