// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Test } from "forge-std/Test.sol";
import { Escrow } from "../../src/Escrow.sol";

contract EscrowTest is Test {
    Escrow escrow;

    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address arbiter = makeAddr("arbiter");
    address owner = makeAddr("owner");
    address buyer2 = makeAddr("buyer2");
    address seller2 = makeAddr("seller2");
    address arbiter2 = makeAddr("arbiter2");
    address owner2 = makeAddr("owner2");

    uint256 constant EXPECTED_AMOUNT = 1 ether;
    uint256 constant PROTOCOL_FEE_BPS = 100; // 1%
    uint256 constant DEPOSIT_WINDOW = 1 days;
    uint256 constant DELIVERY_WINDOW = 7 days;
    uint256 constant EXPECTED_AMOUNT2 = 2 ether;
    uint256 constant PROTOCOL_FEE_BPS2 = 200; // 2%
    uint256 constant DEPOSIT_WINDOW2 = 3 days;
    uint256 constant DELIVERY_WINDOW2 = 14 days;

    function setUp() public {
        escrow = new Escrow(
            buyer, seller, arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, DELIVERY_WINDOW
        );
    }

    function testConstructor_setsImmutables() public view {
        assertEq(escrow.i_buyer(), buyer);
        assertEq(escrow.i_seller(), seller);
        assertEq(escrow.i_arbiter(), arbiter);
        assertEq(escrow.i_owner(), owner);
        assertEq(escrow.i_expectedAmount(), EXPECTED_AMOUNT);
        assertEq(escrow.i_protocolFeeBps(), PROTOCOL_FEE_BPS);
        assertEq(escrow.i_depositDeadline(), block.timestamp + DEPOSIT_WINDOW);
        assertEq(escrow.i_deliveryWindow(), DELIVERY_WINDOW);
    }

    function testConstructor_setsInitialState() public view {
        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.AWAITING_DEPOSIT));
    }

    function testConstructor_setsDepositDeadline() public {
        Escrow escrow2 = new Escrow(
            buyer2, seller2, arbiter2, owner2, EXPECTED_AMOUNT2, PROTOCOL_FEE_BPS2, DEPOSIT_WINDOW2, DELIVERY_WINDOW2
        );
        assertEq(escrow2.i_depositDeadline(), block.timestamp + DEPOSIT_WINDOW2);
    }

    function testConstructor_revertsIfBuyerisZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidAddress.selector);
        new Escrow(
            address(0), seller, arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, DELIVERY_WINDOW
        );
    }

    function testConstructor_revertsIfSellerisZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidAddress.selector);
        new Escrow(
            buyer, address(0), arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, DELIVERY_WINDOW
        );
    }

    function testConstructor_revertsIfArbiterisZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidAddress.selector);
        new Escrow(buyer, seller, address(0), owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, DELIVERY_WINDOW);
    }

    function testConstructor_revertsIfOwnerIsZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidAddress.selector);
        new Escrow(
            buyer, seller, arbiter, address(0), EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, DELIVERY_WINDOW
        );
    }

    function testConstructor_revertsIfBuyerIsSeller() public {
        vm.expectRevert(Escrow.Escrow__SameSellerAndBuyer.selector);
        new Escrow(buyer, buyer, arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, DELIVERY_WINDOW);
    }

    function testConstructor_revertsIfBuyerIsArbiter() public {
        vm.expectRevert(Escrow.Escrow__SameBuyerAndArbiter.selector);
        new Escrow(buyer, seller, buyer, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, DELIVERY_WINDOW);
    }

    function testConstructor_revertsIfSellerIsArbiter() public {
        vm.expectRevert(Escrow.Escrow__SameSellerAndArbiter.selector);
        new Escrow(buyer, seller, seller, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, DELIVERY_WINDOW);
    }

    function testConstructor_revertsIfExpectedAmountIsZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidExpectedAmount.selector);
        new Escrow(buyer, seller, arbiter, owner, 0, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, DELIVERY_WINDOW);
    }

    function testConstructor_revertsIfProtocolFeeTooHigh() public {
        vm.expectRevert(Escrow.Escrow__InvalidProtocolFee.selector);
        new Escrow(buyer, seller, arbiter, owner, EXPECTED_AMOUNT, 1000, DEPOSIT_WINDOW, DELIVERY_WINDOW);
    }

    function testConstructor_revertsIfDepositWindowIsZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidDepositWindow.selector);
        new Escrow(buyer, seller, arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, 0, DELIVERY_WINDOW);
    }

    function testConstructor_acceptsProtocolFeeAtCap() public {
        Escrow escrowAtCap =
            new Escrow(buyer2, seller2, arbiter2, owner2, EXPECTED_AMOUNT, 500, DEPOSIT_WINDOW, DELIVERY_WINDOW);
        assertEq(escrowAtCap.i_protocolFeeBps(), 500);
    }

    function testConstructor_revertsIfDeliveryWindowZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidDeliveryWindow.selector);
        new Escrow(buyer, seller, arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, 0);
    }
}
