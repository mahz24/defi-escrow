# Load environment variables from .env if it exists
-include .env

# Default Anvil private key (account #0) — only for local testing
DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ANVIL_RPC_URL    := http://localhost:8545

.PHONY: help install update build test test-unit test-fuzz test-invariant coverage coverage-lcov \
        format format-check snapshot snapshot-check slither clean anvil deploy-anvil deploy-sepolia verify

help:
	@echo ""
	@echo "Escrow contract — available commands:"
	@echo ""
	@echo "  install         Install/update Foundry dependencies"
	@echo "  build           Compile contracts (forge build)"
	@echo "  test            Run all tests (forge test -vvv)"
	@echo "  test-unit       Run unit + integration tests only"
	@echo "  test-fuzz       Run stateless fuzz tests"
	@echo "  test-invariant  Run stateful invariant tests"
	@echo "  coverage        Show coverage summary for src/"
	@echo "  coverage-lcov   Generate lcov.info (for IDE / HTML reports)"
	@echo "  format          Format Solidity files (forge fmt)"
	@echo "  format-check    Verify formatting without modifying files"
	@echo "  snapshot        Regenerate .gas-snapshot"
	@echo "  snapshot-check  Fail if gas usage changed vs .gas-snapshot"
	@echo "  slither         Run Slither static analysis"
	@echo "  clean           Remove build artifacts"
	@echo "  anvil           Start a local Anvil node"
	@echo "  deploy-anvil    Deploy to local Anvil (requires anvil running)"
	@echo "  deploy-sepolia  Deploy to Sepolia and verify (uses encrypted keystore ACCOUNT)"
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

test-unit:
	@forge test --match-path "test/{unit,integration}/*" -vvv

test-fuzz:
	@forge test --match-path "test/fuzz/*" -vvv

test-invariant:
	@forge test --match-path "test/invariant/*" -vvv

coverage:
	@forge coverage --report summary --no-match-coverage "test|script"

coverage-lcov:
	@forge coverage --report lcov

format:
	@forge fmt

format-check:
	@forge fmt --check

snapshot:
	@forge snapshot --no-match-path "test/{fuzz,invariant}/*"

snapshot-check:
	@forge snapshot --check --no-match-path "test/{fuzz,invariant}/*"

slither:
	@slither .

clean:
	@forge clean

anvil:
	@anvil

deploy-anvil:
	@forge script script/DeployEscrow.s.sol \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(DEFAULT_ANVIL_KEY) \
		--broadcast

# Uses an encrypted keystore instead of a plaintext private key:
#   cast wallet import $(ACCOUNT) --interactive
deploy-sepolia:
	@forge script script/DeployEscrow.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--account $(ACCOUNT) \
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
		--constructor-args $$(cast abi-encode "constructor(address,address,address,address,uint256,uint256,uint256,uint256,uint256)" $$LAST_ARGS)
