# NegRiskAdapter Deployment Script

This directory contains the deployment script for the NegRiskAdapter contract.

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

## Example Output

```
Deploying NegRiskAdapter...
CTF address: 0x7D8610E9567d2a6C9FBf66a5A13E9Ba8bb120d43
Collateral address: 0x2e8dcfe708d44ae2e406a1c02dfe2fa13012f961
Vault address: 0x7f91506c958cE8fb1A7a0A2bd255B22aDeF1053a
NegRiskAdapter deployed at: 0x...
Deployment verification successful!
```
