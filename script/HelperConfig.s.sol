// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Script } from "forge-std/Script.sol";
import { Escrow } from "../src/Escrow.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address buyer;
        address seller;
        address arbiter;
        address owner;
        uint256 expectedAmount;
        uint256 protocolFeeBps;
        uint256 depositWindow;
        uint256 deliveryWindow;
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
            buyer: 0xacb954Ac876F99eDd8E457F58875e79f2527D086,
            seller: 0xbC193d0ac9A800a9502237aff5EBeD5B4E18888e,
            arbiter: 0x2cd3334CEf078e9f8383D8B0BFcDE2084ccB4FeC,
            owner: 0xAfd01a8aD938B63ec7F0166927541c932b5D4684,
            expectedAmount: 0.01 ether,
            protocolFeeBps: 100, // 1%
            depositWindow: 1 days,
            deliveryWindow: 7 days
        });
    }

    function getAnvilConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            buyer: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            seller: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            arbiter: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            owner: 0x90F79bf6EB2c4f870365E785982E1f101E93b906,
            expectedAmount: 0.01 ether,
            protocolFeeBps: 100,
            depositWindow: 1 days,
            deliveryWindow: 7 days
        });
    }

    function getActiveNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }
}
