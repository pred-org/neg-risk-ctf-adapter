#!/bin/bash

# Deploy NegRiskAdapter contract
# Usage: ./script/deploy_neg_risk_adapter.sh [network] [private_key]

set -e

# Default values
NETWORK=${1:-"80001"}  # Default to Mumbai testnet
PRIVATE_KEY=${2:-""}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Deploying NegRiskAdapter to network: ${NETWORK}${NC}"

# Check if private key is provided
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${YELLOW}No private key provided. Using default from environment or wallet.${NC}"
    echo -e "${YELLOW}Make sure you have configured your wallet or set PRIVATE_KEY environment variable.${NC}"
fi

# Set private key if provided
if [ ! -z "$PRIVATE_KEY" ]; then
    export PRIVATE_KEY=$PRIVATE_KEY
fi

# Deploy based on network
case $NETWORK in
    "80001"|"mumbai")
        echo -e "${GREEN}Deploying to Mumbai testnet (80001)${NC}"
        forge script src/scripts/deploy_neg_risk_adapter.s.sol:DeployNegRiskAdapter --rpc-url https://rpc-mumbai.maticvigil.com --broadcast --verify
        ;;
    "137"|"polygon")
        echo -e "${GREEN}Deploying to Polygon mainnet (137)${NC}"
        forge script src/scripts/deploy_neg_risk_adapter.s.sol:DeployNegRiskAdapter --rpc-url https://polygon-rpc.com --broadcast --verify
        ;;
    *)
        echo -e "${RED}Unknown network: $NETWORK${NC}"
        echo -e "${YELLOW}Supported networks: 80001 (Mumbai), 137 (Polygon)${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}Deployment completed!${NC}"
echo -e "${YELLOW}Check the broadcast logs for deployment details.${NC}"
