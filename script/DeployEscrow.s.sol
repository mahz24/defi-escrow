// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Script } from "forge-std/Script.sol";
import { Escrow } from "../src/Escrow.sol";
import { HelperConfig } from "./HelperConfig.s.sol";

contract DeployEscrow is Script {
    function run() external returns (Escrow, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getActiveNetworkConfig();

        vm.startBroadcast();
        Escrow escrow = new Escrow(
            config.buyer,
            config.seller,
            config.arbiter,
            config.owner,
            config.expectedAmount,
            config.protocolFeeBps,
            config.depositWindow,
            config.deliveryWindow
        );
        vm.stopBroadcast();

        return (escrow, helperConfig);
    }
}
