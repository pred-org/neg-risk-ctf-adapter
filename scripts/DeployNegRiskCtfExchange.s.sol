// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {NegRiskCtfExchange} from "src/NegRiskCtfExchange.sol";

/// @title DeployNegRiskCtfExchange
/// @notice Script to deploy the NegRiskCtfExchange contract
/// @author Pred
contract DeployNegRiskCtfExchange is Script {
    /// @notice Deploys the NegRiskCtfExchange contract
    /// @param _collateral The collateral token address (e.g., USDC)
    /// @param _ctf The ConditionalTokens contract address
    /// @param _negRiskAdapter The NegRiskAdapter contract address
    /// @param _proxyFactory The proxy factory address
    /// @param _safeFactory The Gnosis Safe factory address
    /// @return exchange The deployed NegRiskCtfExchange address
    function deploy(
        address _collateral,
        address _ctf,
        address _negRiskAdapter,
        address _proxyFactory,
        address _safeFactory
    ) public returns (address exchange) {
        // Validate inputs
        require(_collateral != address(0), "Invalid collateral address");
        require(_ctf != address(0), "Invalid CTF address");
        require(_negRiskAdapter != address(0), "Invalid NegRiskAdapter address");
        require(_proxyFactory != address(0), "Invalid proxy factory address");
        require(_safeFactory != address(0), "Invalid safe factory address");

        console.log("Deploying NegRiskCtfExchange...");
        console.log("Collateral address:", _collateral);
        console.log("CTF address:", _ctf);
        console.log("NegRiskAdapter address:", _negRiskAdapter);
        console.log("Proxy factory address:", _proxyFactory);
        console.log("Safe factory address:", _safeFactory);

        vm.startBroadcast();
        
        // Deploy the NegRiskCtfExchange
        exchange = address(new NegRiskCtfExchange(
            _collateral,
            _ctf,
            _negRiskAdapter,
            _proxyFactory,
            _safeFactory
        ));
        
        vm.stopBroadcast();

        console.log("NegRiskCtfExchange deployed at:", exchange);

        // Verify the deployment
        NegRiskCtfExchange exchangeContract = NegRiskCtfExchange(exchange);
        // require(address(exchangeContract.col()) == _collateral, "Collateral not set correctly");
        // require(address(exchangeContract.ctf()) == _ctf, "CTF not set correctly");
        require(exchangeContract.getProxyFactory() == _proxyFactory, "Proxy factory not set correctly");
        require(exchangeContract.getSafeFactory() == _safeFactory, "Safe factory not set correctly");

        console.log("Deployment verification successful!");
    }

    /// @notice Deploy with addresses from addresses.json for a specific chain
    /// @param chainId The chain ID to deploy on
    function deployForChain(uint256 chainId) public returns (address exchange) {
        // Load addresses from addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        // Parse the JSON to get addresses for the specific chain
        string memory chainKey = vm.toString(chainId);
        
        address ctf = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".ctf")));
        address usdc = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".usdc")));
        address adapter = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".negRiskAdapter")));
        address proxyFactory = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".proxyFactory")));
        address safeFactory = vm.parseJsonAddress(addressesJson, string(abi.encodePacked(".", chainKey, ".safeFactory")));
        
        console.log("Deploying for chain ID:", chainId);
        return deploy(usdc, ctf, adapter, proxyFactory, safeFactory);
    }

    /// @notice Deploy for Polygon Mumbai testnet
    function deployMumbai() public returns (address exchange) {
        return deployForChain(80001);
    }

    /// @notice Deploy for Polygon mainnet
    function deployPolygon() public returns (address exchange) {
        return deployForChain(137);
    }

    /// @notice Deploy for Monad testnet
    function deployMonad() public returns (address exchange) {
        return deployForChain(10143);
    }

    /// @notice Deploy with custom parameters and save to addresses.json
    /// @param _collateral The collateral token address
    /// @param _ctf The ConditionalTokens contract address
    /// @param _negRiskAdapter The NegRiskAdapter contract address
    /// @param _proxyFactory The proxy factory address
    /// @param _safeFactory The safe factory address
    /// @param chainId The chain ID to save the address for
    function deployAndSave(
        address _collateral,
        address _ctf,
        address _negRiskAdapter,
        address _proxyFactory,
        address _safeFactory,
        uint256 chainId
    ) public returns (address exchange) {
        exchange = deploy(_collateral, _ctf, _negRiskAdapter, _proxyFactory, _safeFactory);
        
        // Save the deployed address to addresses.json
        string memory addressesPath = "./addresses.json";
        string memory addressesJson = vm.readFile(addressesPath);
        
        string memory chainKey = vm.toString(chainId);
        string memory exchangeKey = string(abi.encodePacked(".", chainKey, ".negRiskCtfExchange"));
        
        // Update the JSON with the new exchange address
        string memory updatedJson = vm.serializeAddress(addressesJson, exchangeKey, exchange);
        vm.writeFile(addressesPath, updatedJson);
        
        console.log("Address saved to addresses.json for chain", chainId);
        return exchange;
    }

    /// @notice Deploy with hardcoded factory addresses for testing
    /// @dev These are placeholder addresses - replace with actual factory addresses
    function deployWithHardcodedFactories(
        address _collateral,
        address _ctf,
        address _negRiskAdapter,
        uint256 chainId
    ) public returns (address exchange) {
        // TODO: Replace these with actual factory addresses
        address proxyFactory = 0x0000000000000000000000000000000000000000; // Placeholder
        address safeFactory = 0x0000000000000000000000000000000000000000; // Placeholder
        
        console.log("WARNING: Using placeholder factory addresses!");
        console.log("Please update the script with actual factory addresses before deployment.");
        
        return deployAndSave(_collateral, _ctf, _negRiskAdapter, proxyFactory, safeFactory, chainId);
    }
}
