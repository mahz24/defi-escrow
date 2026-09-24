// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { EscrowFactory } from "../src/EscrowFactory.sol";
import { HelperConfig } from "./HelperConfig.s.sol";

/// @title DeployEscrowFactory
/// @notice Deploys the EscrowFactory (which deploys the Escrow implementation in its constructor).
///         The broadcasting account becomes the factory owner.
contract DeployEscrowFactory is Script {
    function run() external returns (EscrowFactory, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getActiveNetworkConfig();

        vm.startBroadcast();
        EscrowFactory factory = new EscrowFactory(msg.sender, config.feeRecipient, config.protocolFeeBps);
        vm.stopBroadcast();

        return (factory, helperConfig);
    }
}
