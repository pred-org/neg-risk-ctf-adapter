# NegRiskAdapter Deployment Scripts

This directory contains scripts for deploying the NegRiskAdapter contract to different networks.

## Files

- `deploy_neg_risk_adapter.s.sol` - Foundry deployment script
- `deploy_neg_risk_adapter.sh` - Shell script wrapper for easy deployment

## Prerequisites

1. **Foundry installed** - Make sure you have Foundry installed and configured
2. **Environment setup** - Configure your RPC URLs and private keys
3. **Dependencies** - Ensure all project dependencies are installed

## Configuration

### Environment Variables

Set these environment variables before deployment:

```bash
# For Mumbai testnet
export RPC_URL="https://rpc-mumbai.maticvigil.com"
export PRIVATE_KEY="your_private_key_here"

# For Polygon mainnet
export RPC_URL="https://polygon-rpc.com"
export PRIVATE_KEY="your_private_key_here"
```

### Addresses

The deployment script automatically reads addresses from `addresses.json` in the project root. Make sure this file contains the correct addresses for your target network.

## Usage

### Option 1: Using the Shell Script (Recommended)

```bash
# Deploy to Mumbai testnet (default)
./script/deploy_neg_risk_adapter.sh

# Deploy to Mumbai testnet with specific private key
./script/deploy_neg_risk_adapter.sh 80001 0x1234...

# Deploy to Polygon mainnet
./script/deploy_neg_risk_adapter.sh 137

# Deploy to Polygon mainnet with specific private key
./script/deploy_neg_risk_adapter.sh 137 0x1234...
```

### Option 2: Using Foundry Directly

```bash
# Deploy to Mumbai testnet
forge script src/scripts/deploy_neg_risk_adapter.s.sol:DeployNegRiskAdapter \
    --rpc-url https://rpc-mumbai.maticvigil.com \
    --broadcast \
    --verify

# Deploy to Polygon mainnet
forge script src/scripts/deploy_neg_risk_adapter.s.sol:DeployNegRiskAdapter \
    --rpc-url https://polygon-rpc.com \
    --broadcast \
    --verify
```

### Option 3: Using the Script Functions

The Foundry script provides several convenient functions:

```solidity
// Deploy with custom addresses
deploy(ctfAddress, collateralAddress, vaultAddress)

// Deploy to specific network using addresses.json
deployWithNetwork("80001")  // Mumbai
deployWithNetwork("137")    // Polygon

// Convenience functions
deployMumbai()   // Deploy to Mumbai
deployPolygon()  // Deploy to Polygon
```

## Constructor Parameters

The NegRiskAdapter constructor requires three parameters:

1. **`_ctf`** - ConditionalTokens contract address
2. **`_collateral`** - Collateral token address (e.g., USDC)
3. **`_vault`** - Vault address for managing positions

## Verification

The deployment script includes automatic contract verification. Make sure you have:

1. **Etherscan API key** set in your environment
2. **Correct RPC URL** for the target network
3. **Compiler settings** matching your foundry.toml

## Troubleshooting

### Common Issues

1. **Insufficient funds** - Ensure your deployer account has enough native tokens for gas
2. **Wrong network** - Double-check the RPC URL and network ID
3. **Missing addresses** - Verify that `addresses.json` contains all required addresses
4. **Verification failure** - Check that compiler settings match between deployment and verification

### Debug Mode

To run without broadcasting (dry run):

```bash
forge script src/scripts/deploy_neg_risk_adapter.s.sol:DeployNegRiskAdapter \
    --rpc-url <your_rpc_url> \
    --private-key <your_private_key>
```

## Network Information

| Network | Chain ID | RPC URL                           | Explorer                       |
| ------- | -------- | --------------------------------- | ------------------------------ |
| Mumbai  | 80001    | https://rpc-mumbai.maticvigil.com | https://mumbai.polygonscan.com |
| Polygon | 137      | https://polygon-rpc.com           | https://polygonscan.com        |

## Security Notes

- **Never commit private keys** to version control
- **Use environment variables** for sensitive information
- **Verify contract addresses** before deployment
- **Test on testnet first** before mainnet deployment
