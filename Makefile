-include .env

# Anvil default private key
DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

.PHONY: deploy-faucet deploy-sepolia deploy-anvil

# Deploy faucet to Sepolia
deploy-faucet:
    @forge script script/DeployFaucet.s.sol \
        --rpc-url ${SEPOLIA_RPC_URL} \
        --private-key ${PRIVATE_KEY} \
        --broadcast \
        --etherscan-api-key ${ETHERSCAN_API_KEY} \
        --verify \
        -vvvv
    @echo "Faucet deployed successfully!"
    @echo "Faucet address: $$(forge inspect --json $$(forge script script/DeployFaucet.s.sol --rpc-url ${SEPOLIA_RPC_URL} --private-key ${PRIVATE_KEY} --broadcast | jq -r '.deployments[0].address'))"
    @echo "Faucet contract verified on Etherscan!"

# Deploy lending protocol to Sepolia
deploy-sepolia:
    @forge script script/DeployLending.s.sol \
        --rpc-url ${SEPOLIA_RPC_URL} \
        --private-key ${PRIVATE_KEY} \
        --broadcast \
        --etherscan-api-key ${ETHERSCAN_API_KEY} \
        --verify \
        -vvvv
    @echo "Lending contract deployed successfully!"
    @echo "Lending contract address: $$(forge inspect --json $$(forge script script/DeployLending.s.sol --rpc-url ${SEPOLIA_RPC_URL} --private-key ${PRIVATE_KEY} --broadcast | jq -r '.deployments[0].address'))"
    @echo "Lending contract verified on Etherscan!"

# Deploy lending protocol to local Anvil chain
deploy-anvil:
    @forge script script/DeployLending.s.sol \
        --rpc-url http://localhost:8545 \
        --private-key $(DEFAULT_ANVIL_KEY) \
        --broadcast



# --rpc-url: Points to Sepolia/Anvil network
# --private-key: Your deployment wallet's private key
# --broadcast: Actually sends the transaction
# --etherscan-api-key: Required for verification
# --verify: Automatically verifies contracts on Etherscan
# -vvvv: Maximum verbosity for detailed output