// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";

/// @title HelperConfig
/// @notice Returns the factory parameters for the chain the script is running on.
/// @dev On Anvil the fee recipient is the default account #3, so the full flow can be exercised with `cast`.
contract HelperConfig is Script {
    struct NetworkConfig {
        address feeRecipient;
        uint256 protocolFeeBps;
    }

    NetworkConfig private activeNetworkConfig;

    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 public constant ANVIL_CHAIN_ID = 31_337;

    constructor() {
        if (block.chainid == SEPOLIA_CHAIN_ID) {
            activeNetworkConfig = getSepoliaConfig();
        } else {
            activeNetworkConfig = getAnvilConfig();
        }
    }

    function getSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            feeRecipient: 0xAfd01a8aD938B63ec7F0166927541c932b5D4684,
            protocolFeeBps: 100 // 1%
        });
    }

    function getAnvilConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({ feeRecipient: 0x90F79bf6EB2c4f870365E785982E1f101E93b906, protocolFeeBps: 100 });
    }

    function getActiveNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }
}
