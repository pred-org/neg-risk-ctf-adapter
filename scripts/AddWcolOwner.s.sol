// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";
import {NegRiskAdapter} from "src/NegRiskAdapter.sol";

/// @title AddWcolOwner
/// @notice Script to add an owner to the WrappedCollateral contract
/// @author Polymarket
contract AddWcolOwner is Script {
    /// @notice Adds an owner to the WrappedCollateral contract
    /// @param _wcol The WrappedCollateral contract address
    /// @param _newOwner The new owner address to add
    function addOwner(address _wcol, address _newOwner) public {
        require(_wcol != address(0), "Invalid WrappedCollateral address");
        require(_newOwner != address(0), "Invalid new owner address");

        console.log("Adding owner to WrappedCollateral...");
        console.log("WrappedCollateral address:", _wcol);
        console.log("New owner address:", _newOwner);

        vm.startBroadcast();
        
        WrappedCollateral wcol = WrappedCollateral(_wcol);
        wcol.addOwner(_newOwner);
        
        vm.stopBroadcast();

        console.log("Owner added successfully!");
        console.log("Is new owner:", wcol.owners(_newOwner));
    }

    /// @notice Add owner to WCOL for Base Sepolia using addresses from addresses.json
    /// @param _newOwner The new owner address to add
    function addOwnerBaseSepolia(address _newOwner) public {
        // Load addresses from addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        address negRiskAdapter = vm.parseJsonAddress(addressesJson, ".84532.negRiskAdapter");
        
        // Get the WCOL address from NegRiskAdapter
        NegRiskAdapter adapter = NegRiskAdapter(negRiskAdapter);
        address wcol = address(adapter.wcol());
        
        console.log("Adding owner to WCOL for Base Sepolia...");
        console.log("WCOL address:", wcol);
        addOwner(wcol, _newOwner);
    }

    /// @notice Add owner with custom addresses
    /// @param _wcol The WrappedCollateral contract address
    /// @param _newOwner The new owner address to add
    function addOwnerCustom(address _wcol, address _newOwner) public {
        addOwner(_wcol, _newOwner);
    }

    /// @notice Add owner by NegRiskAdapter address (gets WCOL automatically)
    /// @param _negRiskAdapter The NegRiskAdapter contract address
    /// @param _newOwner The new owner address to add
    function addOwnerByAdapter(address _negRiskAdapter, address _newOwner) public {
        require(_negRiskAdapter != address(0), "Invalid NegRiskAdapter address");
        require(_newOwner != address(0), "Invalid new owner address");

        console.log("Getting WCOL from NegRiskAdapter...");
        NegRiskAdapter adapter = NegRiskAdapter(_negRiskAdapter);
        address wcol = address(adapter.wcol());
        
        console.log("WCOL address:", wcol);
        addOwner(wcol, _newOwner);
    }
}
