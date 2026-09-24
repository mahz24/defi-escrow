// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Escrow } from "../../src/Escrow.sol";
import { EscrowFactory } from "../../src/EscrowFactory.sol";
import { DeployEscrowFactory } from "../../script/DeployEscrowFactory.s.sol";
import { HelperConfig } from "../../script/HelperConfig.s.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Runs the real deployment script and drives escrows created from it end to end.
contract DeployEscrowFactoryTest is Test {
    EscrowFactory factory;
    HelperConfig helperConfig;
    HelperConfig.NetworkConfig config;

    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address arbiter = makeAddr("arbiter");

    function setUp() public {
        DeployEscrowFactory deployer = new DeployEscrowFactory();
        (factory, helperConfig) = deployer.run();
        config = helperConfig.getActiveNetworkConfig();
    }

    function _params(address token, uint256 amount) internal view returns (Escrow.EscrowParams memory) {
        return Escrow.EscrowParams({
            buyer: buyer,
            seller: seller,
            arbiter: arbiter,
            token: token,
            amount: amount,
            depositWindow: 1 days,
            deliveryWindow: 7 days,
            disputeWindow: 3 days
        });
    }

    function testDeployScript_wiresConfigIntoFactory() public view {
        assertEq(factory.s_feeRecipient(), config.feeRecipient);
        assertEq(factory.s_protocolFeeBps(), config.protocolFeeBps);
        assertGt(factory.i_implementation().code.length, 0);
        assertEq(factory.getEscrowCount(), 0);
    }

    function testHelperConfig_usesAnvilConfigLocally() public view {
        assertEq(block.chainid, helperConfig.ANVIL_CHAIN_ID());
        assertEq(config.feeRecipient, helperConfig.getAnvilConfig().feeRecipient);
    }

    function testHelperConfig_selectsSepoliaConfigOnSepolia() public {
        vm.chainId(helperConfig.SEPOLIA_CHAIN_ID());
        HelperConfig sepoliaHelper = new HelperConfig();
        HelperConfig.NetworkConfig memory sepolia = sepoliaHelper.getActiveNetworkConfig();

        assertEq(sepolia.feeRecipient, sepoliaHelper.getSepoliaConfig().feeRecipient);
        assertEq(sepolia.protocolFeeBps, 100);
    }

    function testHelperConfig_sepoliaConfigIsValid() public {
        HelperConfig.NetworkConfig memory s = helperConfig.getSepoliaConfig();
        EscrowFactory sepoliaFactory = new EscrowFactory(address(this), s.feeRecipient, s.protocolFeeBps);
        assertEq(sepoliaFactory.s_protocolFeeBps(), s.protocolFeeBps);
    }

    /// ETH happy path through the scripted factory.
    function testDeployedFactory_ethHappyPath() public {
        Escrow escrow = Escrow(factory.createEscrow(_params(address(0), 1 ether), keccak256("eth")));

        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);
        escrow.deposit{ value: 1 ether }();
        escrow.confirmDelivery();
        vm.stopPrank();

        uint256 feeBefore = config.feeRecipient.balance;
        vm.prank(seller);
        escrow.withdraw();
        vm.prank(config.feeRecipient);
        escrow.withdraw();

        assertEq(seller.balance, escrow.getSellerPayout());
        assertEq(config.feeRecipient.balance - feeBefore, escrow.getProtocolFee());
        assertEq(address(escrow).balance, 0);
    }

    /// ERC-20 dispute where the arbiter never shows up: the buyer still gets every token back.
    function testDeployedFactory_erc20AbsentArbiterCannotLockFunds() public {
        MockERC20 usd = new MockERC20("Mock USD", "mUSD", 6);
        Escrow escrow = Escrow(factory.createEscrow(_params(address(usd), 500e6), keccak256("usd")));

        usd.mint(buyer, 500e6);
        vm.startPrank(buyer);
        usd.approve(address(escrow), 500e6);
        escrow.deposit();
        vm.stopPrank();

        vm.prank(seller);
        escrow.openDispute();
        vm.warp(escrow.s_disputeDeadline() + 1);
        escrow.refundOnDisputeTimeout();

        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usd.balanceOf(buyer), 500e6);
        assertEq(usd.balanceOf(address(escrow)), 0);
    }

    /// Participants can find all their trades through the factory index.
    function testDeployedFactory_indexesTradesPerParticipant() public {
        MockERC20 usd = new MockERC20("Mock USD", "mUSD", 6);
        address a = factory.createEscrow(_params(address(0), 1 ether), keccak256("1"));
        address b = factory.createEscrow(_params(address(usd), 100e6), keccak256("2"));

        address[] memory sellerTrades = factory.getEscrowsByParticipant(seller, 0, 10);
        assertEq(sellerTrades.length, 2);
        assertEq(sellerTrades[0], a);
        assertEq(sellerTrades[1], b);
    }
}
