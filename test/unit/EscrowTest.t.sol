// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Test } from "forge-std/Test.sol";
import { Escrow } from "../../src/Escrow.sol";
import { RejectingReceiver } from "../mocks/RejectingReceiver.sol";

contract EscrowTest is Test {
    Escrow escrow;

    // TEST CONSTANTS
    uint256 constant EXPECTED_AMOUNT = 1 ether;
    uint256 constant PROTOCOL_FEE_BPS = 100; // 1%
    uint256 constant DEPOSIT_WINDOW = 1 days;
    uint256 constant DELIVERY_WINDOW = 7 days;
    uint256 constant EXPECTED_AMOUNT2 = 2 ether;
    uint256 constant PROTOCOL_FEE_BPS2 = 200; // 2%
    uint256 constant DEPOSIT_WINDOW2 = 3 days;
    uint256 constant DELIVERY_WINDOW2 = 14 days;
    uint256 constant BPS_DIVISOR = 10_000;
    uint256 constant FEE = EXPECTED_AMOUNT * PROTOCOL_FEE_BPS / BPS_DIVISOR;
    uint256 constant SELLER_AMOUNT = EXPECTED_AMOUNT - FEE;

    // TEST ADDRESSES
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address arbiter = makeAddr("arbiter");
    address owner = makeAddr("owner");
    address buyer2 = makeAddr("buyer2");
    address seller2 = makeAddr("seller2");
    address arbiter2 = makeAddr("arbiter2");
    address owner2 = makeAddr("owner2");

    // TEST EVENTS
    event Deposited(address indexed buyer, uint256 amount);
    event DeliveryConfirmed(address indexed seller, uint256 amount);
    event DisputeOpened(address indexed openedBy);
    event DisputeResolved(bool releaseToSeller);
    event Refunded(address indexed buyer, uint256 amount);
    event Withdrawn(address indexed recipient, uint256 amount);

    // TEST MODIFIERS
    modifier withActiveEscrow() {
        vm.deal(buyer, EXPECTED_AMOUNT);
        vm.prank(buyer);
        escrow.deposit{ value: EXPECTED_AMOUNT }();
        _;
    }

    modifier withCompletedEscrow() {
        vm.deal(buyer, EXPECTED_AMOUNT);
        vm.prank(buyer);
        escrow.deposit{ value: EXPECTED_AMOUNT }();
        vm.prank(buyer);
        escrow.confirmDelivery();
        _;
    }

    modifier withDisputedEscrow() {
        vm.deal(buyer, EXPECTED_AMOUNT);
        vm.prank(buyer);
        escrow.deposit{ value: EXPECTED_AMOUNT }();

        vm.prank(buyer);
        escrow.openDispute();
        _;
    }

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

    function testDeposit_happyPath() public {
        vm.deal(buyer, EXPECTED_AMOUNT);
        vm.prank(buyer);
        escrow.deposit{ value: EXPECTED_AMOUNT }();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.AWAITING_DELIVERY));
        assertEq(address(escrow).balance, EXPECTED_AMOUNT);
        assertEq(escrow.s_deliveryDeadline(), block.timestamp + DELIVERY_WINDOW);
    }

    function testDeposit_emitsDeposited() public {
        vm.deal(buyer, EXPECTED_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit Deposited(buyer, EXPECTED_AMOUNT);

        vm.prank(buyer);
        escrow.deposit{ value: EXPECTED_AMOUNT }();
    }

    function testDeposit_revertsIfNotBuyer() public {
        vm.deal(seller, EXPECTED_AMOUNT);
        vm.prank(seller);
        vm.expectRevert(Escrow.Escrow__NotBuyer.selector);
        escrow.deposit{ value: EXPECTED_AMOUNT }();
    }

    function testDeposit_revertsIfNotInAwaitingDeposit() public {
        vm.deal(buyer, 2 * EXPECTED_AMOUNT);
        vm.prank(buyer);
        escrow.deposit{ value: EXPECTED_AMOUNT }();

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.Escrow__WrongState.selector, Escrow.State.AWAITING_DEPOSIT, Escrow.State.AWAITING_DELIVERY
            )
        );
        escrow.deposit{ value: EXPECTED_AMOUNT }();
    }

    function testDeposit_revertsIfWrongAmount() public {
        vm.deal(buyer, EXPECTED_AMOUNT);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.Escrow__WrongPaymentAmount.selector, 0, EXPECTED_AMOUNT));
        escrow.deposit{ value: 0 }();
    }

    function testDeposit_revertsIfAmountTooHigh() public {
        vm.deal(buyer, 2 * EXPECTED_AMOUNT);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(Escrow.Escrow__WrongPaymentAmount.selector, 2 * EXPECTED_AMOUNT, EXPECTED_AMOUNT)
        );
        escrow.deposit{ value: 2 * EXPECTED_AMOUNT }();
    }

    function testDeposit_revertsAfterDeadline() public {
        vm.warp(block.timestamp + DEPOSIT_WINDOW + 1);
        vm.deal(buyer, EXPECTED_AMOUNT);
        vm.prank(buyer);
        vm.expectRevert(Escrow.Escrow__DepositWindowExpired.selector);
        escrow.deposit{ value: EXPECTED_AMOUNT }();
    }

    function testConfirmDelivery_happyPath() public withActiveEscrow {
        vm.prank(buyer);
        escrow.confirmDelivery();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.COMPLETE));
    }

    function testConfirmDelivery_creditsSellerAndOwner() public withActiveEscrow {
        vm.prank(buyer);
        escrow.confirmDelivery();

        assertEq(escrow.s_pendingWithdrawals(seller), SELLER_AMOUNT);
        assertEq(escrow.s_pendingWithdrawals(owner), FEE);
    }

    function testConfirmDelivery_emitsDeliveryConfirmed() public withActiveEscrow {
        vm.expectEmit(true, false, false, true);
        emit DeliveryConfirmed(seller, EXPECTED_AMOUNT);

        vm.prank(buyer);
        escrow.confirmDelivery();
    }

    function testConfirmDelivery_revertsIfNotBuyer() public withActiveEscrow {
        vm.prank(seller);
        vm.expectRevert(Escrow.Escrow__NotBuyer.selector);
        escrow.confirmDelivery();
    }

    function testConfirmDelivery_revertsIfWrongState() public {
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.Escrow__WrongState.selector, Escrow.State.AWAITING_DELIVERY, Escrow.State.AWAITING_DEPOSIT
            )
        );
        escrow.confirmDelivery();
    }

    function testConfirmDelivery_revertsIfAlreadyConfirmed() public withCompletedEscrow {
        // Estado ya es COMPLETE por el modifier
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.Escrow__WrongState.selector, Escrow.State.AWAITING_DELIVERY, Escrow.State.COMPLETE
            )
        );
        escrow.confirmDelivery();
    }

    function testWithdraw_sellerHappyPath() public withCompletedEscrow {
        vm.prank(seller);
        escrow.withdraw();

        assertEq(address(seller).balance, SELLER_AMOUNT);
        assertEq(escrow.s_pendingWithdrawals(seller), 0);
        assertEq(address(escrow).balance, FEE);
    }

    function testWithdraw_ownerHappyPath() public withCompletedEscrow {
        vm.prank(owner);
        escrow.withdraw();

        assertEq(address(owner).balance, FEE);
        assertEq(escrow.s_pendingWithdrawals(owner), 0);
    }

    function testWithdraw_revertsIfNothingPending() public withCompletedEscrow {
        vm.prank(arbiter);
        vm.expectRevert(Escrow.Escrow__NothingToWithdraw.selector);
        escrow.withdraw();
    }

    function testWithdraw_revertsIfEscrowNotFinalized() public withActiveEscrow {
        vm.prank(seller);
        vm.expectRevert(Escrow.Escrow__EscrowNotFinalized.selector);
        escrow.withdraw();
    }

    function testWithdraw_emitsWithdrawn() public withCompletedEscrow {
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(seller, SELLER_AMOUNT);

        vm.prank(seller);
        escrow.withdraw();
    }

    function testOpenDispute_byBuyer() public withActiveEscrow {
        vm.prank(buyer);
        escrow.openDispute();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.DISPUTED));
    }

    function testOpenDispute_bySeller() public withActiveEscrow {
        vm.prank(seller);
        escrow.openDispute();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.DISPUTED));
    }

    function testOpenDispute_emitsDisputeOpened() public withActiveEscrow {
        vm.expectEmit(true, false, false, false);
        emit DisputeOpened(buyer);

        vm.prank(buyer);
        escrow.openDispute();
    }

    function testOpenDispute_revertsIfNotSellerOrBuyer() public withActiveEscrow {
        vm.prank(arbiter);
        vm.expectRevert(Escrow.Escrow__NotSellerOrBuyer.selector);
        escrow.openDispute();
    }

    function testOpenDispute_revertsIfWrongState() public {
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.Escrow__WrongState.selector, Escrow.State.AWAITING_DELIVERY, Escrow.State.AWAITING_DEPOSIT
            )
        );
        escrow.openDispute();
    }

    function testResolveDispute_releaseToSeller_setsComplete() public withDisputedEscrow {
        vm.prank(arbiter);
        escrow.resolveDispute(true);

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.COMPLETE));
    }

    function testResolveDispute_releaseToSeller_creditsSellerAndOwner() public withDisputedEscrow {
        vm.prank(arbiter);
        escrow.resolveDispute(true);

        assertEq(escrow.s_pendingWithdrawals(seller), SELLER_AMOUNT);
        assertEq(escrow.s_pendingWithdrawals(owner), FEE);
    }

    function testResolveDispute_refundBuyer_setsRefunded() public withDisputedEscrow {
        vm.prank(arbiter);
        escrow.resolveDispute(false);

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.REFUNDED));
    }

    function testResolveDispute_refundBuyer_creditsBuyerFully() public withDisputedEscrow {
        vm.prank(arbiter);
        escrow.resolveDispute(false);

        assertEq(escrow.s_pendingWithdrawals(buyer), EXPECTED_AMOUNT);
        assertEq(escrow.s_pendingWithdrawals(seller), 0);
        assertEq(escrow.s_pendingWithdrawals(owner), 0);
    }

    function testResolveDispute_emitsDisputeResolved() public withDisputedEscrow {
        vm.expectEmit(false, false, false, true);
        emit DisputeResolved(true);

        vm.prank(arbiter);
        escrow.resolveDispute(true);
    }

    function testResolveDispute_revertsIfNotArbiter() public withDisputedEscrow {
        vm.prank(seller);
        vm.expectRevert(Escrow.Escrow__NotArbiter.selector);
        escrow.resolveDispute(true);
    }

    function testResolveDispute_revertsIfWrongState() public {
        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.Escrow__WrongState.selector, Escrow.State.DISPUTED, Escrow.State.AWAITING_DEPOSIT
            )
        );
        escrow.resolveDispute(true);
    }

    function testRefundOnTimeout_happyPath() public withActiveEscrow {
        vm.warp(escrow.s_deliveryDeadline() + 1);

        escrow.refundOnTimeout();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.REFUNDED));
    }

    function testRefundOnTimeout_creditsBuyerFully() public withActiveEscrow {
        vm.warp(escrow.s_deliveryDeadline() + 1);
        escrow.refundOnTimeout();

        assertEq(escrow.s_pendingWithdrawals(buyer), EXPECTED_AMOUNT);
        assertEq(escrow.s_pendingWithdrawals(seller), 0);
        assertEq(escrow.s_pendingWithdrawals(owner), 0);
    }

    function testRefundOnTimeout_emitsRefunded() public withActiveEscrow {
        vm.warp(escrow.s_deliveryDeadline() + 1);

        vm.expectEmit(true, false, false, true);
        emit Refunded(buyer, EXPECTED_AMOUNT);

        escrow.refundOnTimeout();
    }

    function testRefundOnTimeout_anyoneCanCall() public withActiveEscrow {
        vm.warp(escrow.s_deliveryDeadline() + 1);

        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        escrow.refundOnTimeout();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.REFUNDED));
        assertEq(escrow.s_pendingWithdrawals(buyer), EXPECTED_AMOUNT);
    }

    function testRefundOnTimeout_revertsIfBeforeDeadline() public withActiveEscrow {
        vm.warp(escrow.s_deliveryDeadline());

        vm.expectRevert(Escrow.Escrow__DeliveryWindowNotExpired.selector);
        escrow.refundOnTimeout();
    }

    function testRefundOnTimeout_revertsIfWrongState() public {
        vm.warp(escrow.s_deliveryDeadline() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Escrow.Escrow__WrongState.selector, Escrow.State.AWAITING_DELIVERY, Escrow.State.AWAITING_DEPOSIT
            )
        );
        escrow.refundOnTimeout();
    }

    function testWithdraw_revertsIfCallFails() public {
      RejectingReceiver rejectingSeller = new RejectingReceiver();

      Escrow escrowWithRejecting = new Escrow(
          buyer, address(rejectingSeller), arbiter, owner,
          EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, DELIVERY_WINDOW
      );

      vm.deal(buyer, EXPECTED_AMOUNT);
      vm.prank(buyer);
      escrowWithRejecting.deposit{ value: EXPECTED_AMOUNT }();

      vm.prank(buyer);
      escrowWithRejecting.confirmDelivery();

      vm.prank(address(rejectingSeller));
      vm.expectRevert(Escrow.Escrow__WithdrawalFailed.selector);
      escrowWithRejecting.withdraw();
  }
}
