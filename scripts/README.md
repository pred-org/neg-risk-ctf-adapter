# NegRiskAdapter Deployment Scripts

This directory contains deployment scripts for the NegRiskAdapter and NegRiskCtfExchange contracts.

## Usage

### Deploy with custom parameters

```bash
forge script scripts/DeployNegRiskAdapter.s.sol:DeployNegRiskAdapter --sig "deploy(address,address,address)" <CTF_ADDRESS> <COLLATERAL_ADDRESS> <VAULT_ADDRESS> --rpc-url <RPC_URL> --broadcast
```

### Deploy for specific chains using addresses.json

```bash
# Deploy for Polygon Mumbai testnet
forge script scripts/DeployNegRiskAdapter.s.sol:DeployNegRiskAdapter --sig "deployMumbai()" --rpc-url <MUMBAI_RPC_URL> --broadcast

# Deploy for Polygon mainnet
forge script scripts/DeployNegRiskAdapter.s.sol:DeployNegRiskAdapter --sig "deployPolygon()" --rpc-url <POLYGON_RPC_URL> --broadcast

# Deploy for any chain by chain ID
forge script scripts/DeployNegRiskAdapter.s.sol:DeployNegRiskAdapter --sig "deployForChain(uint256)" <CHAIN_ID> --rpc-url <RPC_URL> --broadcast
```

### Deploy and save address to addresses.json

```bash
forge script scripts/DeployNegRiskAdapter.s.sol:DeployNegRiskAdapter --sig "deployAndSave(address,address,address,uint256)" <CTF_ADDRESS> <COLLATERAL_ADDRESS> <VAULT_ADDRESS> <CHAIN_ID> --rpc-url <RPC_URL> --broadcast
```

## Constructor Parameters

The NegRiskAdapter constructor requires:

- `_ctf`: The ConditionalTokens contract address
- `_collateral`: The collateral token address (e.g., USDC)
- `_vault`: The vault address for fee collection

## Available Functions

- `deploy(address,address,address)`: Deploy with custom parameters
- `deployForChain(uint256)`: Deploy using addresses from addresses.json for a specific chain
- `deployMumbai()`: Deploy for Polygon Mumbai testnet (chain ID: 80001)
- `deployPolygon()`: Deploy for Polygon mainnet (chain ID: 137)
- `deployAndSave(address,address,address,uint256)`: Deploy and save address to addresses.json

## Verification

The script includes automatic verification of the deployed contract by checking that:

- The CTF address is set correctly
- The collateral token address is set correctly
- The vault address is set correctly

## NegRiskCtfExchange Deployment

### Deploy with custom parameters

```bash
forge script scripts/DeployNegRiskCtfExchange.s.sol:DeployNegRiskCtfExchange --sig "deploy(address,address,address,address,address)" <COLLATERAL_ADDRESS> <CTF_ADDRESS> <NEGRISK_ADAPTER_ADDRESS> <PROXY_FACTORY_ADDRESS> <SAFE_FACTORY_ADDRESS> --rpc-url <RPC_URL> --broadcast
```

### Deploy for specific chains using addresses.json

```bash
# Deploy for Polygon Mumbai testnet
forge script scripts/DeployNegRiskCtfExchange.s.sol:DeployNegRiskCtfExchange --sig "deployMumbai()" --rpc-url <MUMBAI_RPC_URL> --broadcast

# Deploy for Polygon mainnet
forge script scripts/DeployNegRiskCtfExchange.s.sol:DeployNegRiskCtfExchange --sig "deployPolygon()" --rpc-url <POLYGON_RPC_URL> --broadcast

# Deploy for any chain by chain ID
forge script scripts/DeployNegRiskCtfExchange.s.sol:DeployNegRiskCtfExchange --sig "deployForChain(uint256)" <CHAIN_ID> --rpc-url <RPC_URL> --broadcast
```

### Deploy and save address to addresses.json

```bash
forge script scripts/DeployNegRiskCtfExchange.s.sol:DeployNegRiskCtfExchange --sig "deployAndSave(address,address,address,address,address,uint256)" <COLLATERAL_ADDRESS> <CTF_ADDRESS> <NEGRISK_ADAPTER_ADDRESS> <PROXY_FACTORY_ADDRESS> <SAFE_FACTORY_ADDRESS> <CHAIN_ID> --rpc-url <RPC_URL> --broadcast
```

## NegRiskCtfExchange Constructor Parameters

The NegRiskCtfExchange constructor requires:

- `_collateral`: The collateral token address (e.g., USDC)
- `_ctf`: The ConditionalTokens contract address
- `_negRiskAdapter`: The NegRiskAdapter contract address
- `_proxyFactory`: The PRED proxy factory address
- `_safeFactory`: The Gnosis Safe factory address

## NegRiskCtfExchange Available Functions

- `deploy(address,address,address,address,address)`: Deploy with custom parameters
- `deployForChain(uint256)`: Deploy using addresses from addresses.json for a specific chain
- `deployMumbai()`: Deploy for Polygon Mumbai testnet (chain ID: 80001)
- `deployPolygon()`: Deploy for Polygon mainnet (chain ID: 137)
- `deployAndSave(address,address,address,address,address,uint256)`: Deploy and save address to addresses.json
- `deployWithHardcodedFactories(address,address,address,uint256)`: Deploy with placeholder factory addresses (for testing)

## Factory Addresses

**Important**: The proxy factory and safe factory addresses need to be configured in `addresses.json` before deployment. Currently, they are set to placeholder addresses (`0x0000000000000000000000000000000000000000`).

To find the correct factory addresses:

1. Check PRED's documentation or deployed contracts
2. Look for existing CTFExchange deployments on the target network
3. Contact the PRED team for the official factory addresses

## Example Output

```
Deploying NegRiskAdapter...
CTF address: 0x7D8610E9567d2a6C9FBf66a5A13E9Ba8bb120d43
Collateral address: 0x2e8dcfe708d44ae2e406a1c02dfe2fa13012f961
Vault address: 0x7f91506c958cE8fb1A7a0A2bd255B22aDeF1053a
NegRiskAdapter deployed at: 0x...
Deployment verification successful!
```

```
Deploying NegRiskCtfExchange...
Collateral address: 0x2e8dcfe708d44ae2e406a1c02dfe2fa13012f961
CTF address: 0x7D8610E9567d2a6C9FBf66a5A13E9Ba8bb120d43
NegRiskAdapter address: 0x9A6930BB811fe3dFE1c35e4502134B38EC54399C
Proxy factory address: 0x...
Safe factory address: 0x...
NegRiskCtfExchange deployed at: 0x...
Deployment verification successful!
```
