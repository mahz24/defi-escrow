// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Test } from "forge-std/Test.sol";
import { Escrow } from "../../src/Escrow.sol";
import { DeployEscrow } from "../../script/DeployEscrow.s.sol";
import { HelperConfig } from "../../script/HelperConfig.s.sol";

/// @notice Runs the real deployment script and drives the deployed escrow end to end.
contract DeployEscrowTest is Test {
    Escrow escrow;
    HelperConfig helperConfig;
    HelperConfig.NetworkConfig config;

    function setUp() public {
        DeployEscrow deployer = new DeployEscrow();
        (escrow, helperConfig) = deployer.run();
        config = helperConfig.getActiveNetworkConfig();
    }

    function testDeployScript_wiresConfigIntoEscrow() public view {
        assertEq(escrow.i_buyer(), config.buyer);
        assertEq(escrow.i_seller(), config.seller);
        assertEq(escrow.i_arbiter(), config.arbiter);
        assertEq(escrow.i_owner(), config.owner);
        assertEq(escrow.i_expectedAmount(), config.expectedAmount);
        assertEq(escrow.i_protocolFeeBps(), config.protocolFeeBps);
        assertEq(escrow.i_deliveryWindow(), config.deliveryWindow);
        assertEq(escrow.i_disputeWindow(), config.disputeWindow);
        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.AWAITING_DEPOSIT));
    }

    function testHelperConfig_usesAnvilConfigLocally() public view {
        assertEq(block.chainid, helperConfig.ANVIL_CHAIN_ID());
        assertEq(config.buyer, helperConfig.getAnvilConfig().buyer);
    }

    function testHelperConfig_selectsSepoliaConfigOnSepolia() public {
        vm.chainId(helperConfig.SEPOLIA_CHAIN_ID());
        HelperConfig sepoliaHelper = new HelperConfig();
        HelperConfig.NetworkConfig memory sepolia = sepoliaHelper.getActiveNetworkConfig();

        assertEq(sepolia.buyer, sepoliaHelper.getSepoliaConfig().buyer);
        assertEq(sepolia.protocolFeeBps, 100);
    }

    function testHelperConfig_configsAreValidEscrowParams() public {
        HelperConfig.NetworkConfig memory s = helperConfig.getSepoliaConfig();
        Escrow sepoliaEscrow = new Escrow(
            s.buyer,
            s.seller,
            s.arbiter,
            s.owner,
            s.expectedAmount,
            s.protocolFeeBps,
            s.depositWindow,
            s.deliveryWindow,
            s.disputeWindow
        );
        assertEq(sepoliaEscrow.i_seller(), s.seller);
    }

    /// Full happy-path lifecycle against the scripted deployment.
    function testDeployedEscrow_fullHappyPath() public {
        vm.deal(config.buyer, config.expectedAmount);
        vm.startPrank(config.buyer);
        escrow.deposit{ value: config.expectedAmount }();
        escrow.confirmDelivery();
        vm.stopPrank();

        uint256 sellerBefore = config.seller.balance;
        uint256 ownerBefore = config.owner.balance;
        vm.prank(config.seller);
        escrow.withdraw();
        vm.prank(config.owner);
        escrow.withdraw();

        assertEq(config.seller.balance - sellerBefore, escrow.getSellerPayout());
        assertEq(config.owner.balance - ownerBefore, escrow.getProtocolFee());
        assertEq(address(escrow).balance, 0);
    }

    /// Full dispute lifecycle where the arbiter never shows up.
    function testDeployedEscrow_absentArbiterCannotLockFunds() public {
        vm.deal(config.buyer, config.expectedAmount);
        vm.prank(config.buyer);
        escrow.deposit{ value: config.expectedAmount }();
        vm.prank(config.seller);
        escrow.openDispute();

        vm.warp(escrow.s_disputeDeadline() + 1);
        escrow.refundOnDisputeTimeout();

        uint256 buyerBefore = config.buyer.balance;
        vm.prank(config.buyer);
        escrow.withdraw();
        assertEq(config.buyer.balance - buyerBefore, config.expectedAmount);
        assertEq(address(escrow).balance, 0);
    }
}
