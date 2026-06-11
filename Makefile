# Load environment variables from .env if it exists
-include .env

# Default Anvil private key (account #0) — only for local testing
DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ANVIL_RPC_URL    := http://localhost:8545

.PHONY: help install update build test coverage format format-check snapshot \
        clean anvil deploy-anvil deploy-sepolia verify

help:
	@echo ""
	@echo "Escrow contract — available commands:"
	@echo ""
	@echo "  install         Install/update Foundry dependencies"
	@echo "  build           Compile contracts (forge build)"
	@echo "  test            Run all tests (forge test -vvv)"
	@echo "  coverage        Show coverage summary"
	@echo "  format          Format Solidity files (forge fmt)"
	@echo "  format-check    Verify formatting without modifying files"
	@echo "  snapshot        Generate gas snapshot"
	@echo "  clean           Remove build artifacts"
	@echo "  anvil           Start a local Anvil node"
	@echo "  deploy-anvil    Deploy to local Anvil (requires anvil running)"
	@echo "  deploy-sepolia  Deploy to Sepolia and verify on Etherscan"
	@echo "  verify          Re-verify the latest Sepolia deployment"
	@echo ""

install:
	@forge install

update:
	@forge update

build:
	@forge build

test:
	@forge test -vvv

coverage:
	@forge coverage --report summary

format:
	@forge fmt

format-check:
	@forge fmt --check

snapshot:
	@forge snapshot

clean:
	@forge clean

anvil:
	@anvil

deploy-anvil:
	@forge script script/DeployEscrow.s.sol \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(DEFAULT_ANVIL_KEY) \
		--broadcast

deploy-sepolia:
	@forge script script/DeployEscrow.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY)

# Re-verify the latest Sepolia deployment (use when --verify timed out)
# Reads address from broadcast/DeployEscrow.s.sol/11155111/run-latest.json
verify:
	@LAST_ADDR=$$(jq -r '.transactions[] | select(.contractName=="Escrow") | .contractAddress' broadcast/DeployEscrow.s.sol/11155111/run-latest.json); \
	LAST_ARGS=$$(jq -r '.transactions[] | select(.contractName=="Escrow") | .arguments | join(" ")' broadcast/DeployEscrow.s.sol/11155111/run-latest.json); \
	echo "Re-verifying $$LAST_ADDR ..."; \
	forge verify-contract $$LAST_ADDR src/Escrow.sol:Escrow \
		--chain sepolia \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--constructor-args $$(cast abi-encode "constructor(address,address,address,address,uint256,uint256,uint256,uint256)" $$LAST_ARGS)
