// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Test } from "forge-std/Test.sol";
import { Escrow } from "../../src/Escrow.sol";
import { RejectingReceiver } from "../mocks/RejectingReceiver.sol";
import { ReentrantReceiver } from "../mocks/ReentrantReceiver.sol";

contract EscrowTest is Test {
    Escrow escrow;

    // TEST CONSTANTS
    uint256 constant EXPECTED_AMOUNT = 1 ether;
    uint256 constant PROTOCOL_FEE_BPS = 100; // 1%
    uint256 constant DEPOSIT_WINDOW = 1 days;
    uint256 constant DELIVERY_WINDOW = 7 days;
    uint256 constant DISPUTE_WINDOW = 3 days;
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
    event Deposited(address indexed buyer, uint256 amount, uint256 deliveryDeadline);
    event DeliveryConfirmed(address indexed seller, uint256 amount);
    event ProtocolFeeCharged(address indexed owner, uint256 fee);
    event DisputeOpened(address indexed openedBy, uint256 disputeDeadline);
    event DisputeResolved(address indexed recipient, bool releaseToSeller, uint256 amount);
    event Refunded(address indexed buyer, uint256 amount);
    event Withdrawn(address indexed recipient, uint256 amount);

    // TEST MODIFIERS
    modifier withActiveEscrow() {
        _deposit();
        _;
    }

    modifier withCompletedEscrow() {
        _deposit();
        vm.prank(buyer);
        escrow.confirmDelivery();
        _;
    }

    modifier withDisputedEscrow() {
        _deposit();
        vm.prank(buyer);
        escrow.openDispute();
        _;
    }

    function setUp() public {
        escrow = _newEscrow(buyer, seller, arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function _newEscrow(address b, address s, address a, address o, uint256 amount, uint256 feeBps)
        internal
        returns (Escrow)
    {
        return new Escrow(b, s, a, o, amount, feeBps, DEPOSIT_WINDOW, DELIVERY_WINDOW, DISPUTE_WINDOW);
    }

    function _deposit() internal {
        vm.deal(buyer, EXPECTED_AMOUNT);
        vm.prank(buyer);
        escrow.deposit{ value: EXPECTED_AMOUNT }();
    }

    function _wrongState(Escrow.State expected, Escrow.State current) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Escrow.Escrow__WrongState.selector, expected, current);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    function testConstructor_setsImmutables() public view {
        assertEq(escrow.i_buyer(), buyer);
        assertEq(escrow.i_seller(), seller);
        assertEq(escrow.i_arbiter(), arbiter);
        assertEq(escrow.i_owner(), owner);
        assertEq(escrow.i_expectedAmount(), EXPECTED_AMOUNT);
        assertEq(escrow.i_protocolFeeBps(), PROTOCOL_FEE_BPS);
        assertEq(escrow.i_depositDeadline(), block.timestamp + DEPOSIT_WINDOW);
        assertEq(escrow.i_deliveryWindow(), DELIVERY_WINDOW);
        assertEq(escrow.i_disputeWindow(), DISPUTE_WINDOW);
    }

    function testConstructor_setsInitialState() public view {
        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.AWAITING_DEPOSIT));
        assertEq(escrow.s_deliveryDeadline(), 0);
        assertEq(escrow.s_disputeDeadline(), 0);
    }

    function testConstructor_setsDepositDeadline() public {
        Escrow escrow2 = new Escrow(
            buyer2,
            seller2,
            arbiter2,
            owner2,
            EXPECTED_AMOUNT2,
            PROTOCOL_FEE_BPS2,
            DEPOSIT_WINDOW2,
            DELIVERY_WINDOW2,
            DISPUTE_WINDOW
        );
        assertEq(escrow2.i_depositDeadline(), block.timestamp + DEPOSIT_WINDOW2);
    }

    function testConstructor_revertsIfBuyerisZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidAddress.selector);
        _newEscrow(address(0), seller, arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS);
    }

    function testConstructor_revertsIfSellerisZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidAddress.selector);
        _newEscrow(buyer, address(0), arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS);
    }

    function testConstructor_revertsIfArbiterisZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidAddress.selector);
        _newEscrow(buyer, seller, address(0), owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS);
    }

    function testConstructor_revertsIfOwnerIsZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidAddress.selector);
        _newEscrow(buyer, seller, arbiter, address(0), EXPECTED_AMOUNT, PROTOCOL_FEE_BPS);
    }

    function testConstructor_revertsIfBuyerIsSeller() public {
        vm.expectRevert(Escrow.Escrow__SameSellerAndBuyer.selector);
        _newEscrow(buyer, buyer, arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS);
    }

    function testConstructor_revertsIfBuyerIsArbiter() public {
        vm.expectRevert(Escrow.Escrow__SameBuyerAndArbiter.selector);
        _newEscrow(buyer, seller, buyer, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS);
    }

    function testConstructor_revertsIfSellerIsArbiter() public {
        vm.expectRevert(Escrow.Escrow__SameSellerAndArbiter.selector);
        _newEscrow(buyer, seller, seller, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS);
    }

    function testConstructor_revertsIfExpectedAmountIsZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidExpectedAmount.selector);
        _newEscrow(buyer, seller, arbiter, owner, 0, PROTOCOL_FEE_BPS);
    }

    function testConstructor_revertsIfProtocolFeeTooHigh() public {
        uint256 maxFee = escrow.MAX_PROTOCOL_FEE_BPS();
        vm.expectRevert(Escrow.Escrow__InvalidProtocolFee.selector);
        _newEscrow(buyer, seller, arbiter, owner, EXPECTED_AMOUNT, maxFee + 1);
    }

    function testConstructor_acceptsProtocolFeeAtCap() public {
        Escrow escrowAtCap = _newEscrow(buyer2, seller2, arbiter2, owner2, EXPECTED_AMOUNT, 500);
        assertEq(escrowAtCap.i_protocolFeeBps(), escrow.MAX_PROTOCOL_FEE_BPS());
    }

    function testConstructor_acceptsZeroProtocolFee() public {
        Escrow freeEscrow = _newEscrow(buyer2, seller2, arbiter2, owner2, EXPECTED_AMOUNT, 0);
        assertEq(freeEscrow.getProtocolFee(), 0);
        assertEq(freeEscrow.getSellerPayout(), EXPECTED_AMOUNT);
    }

    function testConstructor_revertsIfDepositWindowIsZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidDepositWindow.selector);
        new Escrow(buyer, seller, arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, 0, DELIVERY_WINDOW, DISPUTE_WINDOW);
    }

    function testConstructor_revertsIfDeliveryWindowZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidDeliveryWindow.selector);
        new Escrow(buyer, seller, arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, 0, DISPUTE_WINDOW);
    }

    function testConstructor_revertsIfDisputeWindowZero() public {
        vm.expectRevert(Escrow.Escrow__InvalidDisputeWindow.selector);
        new Escrow(buyer, seller, arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS, DEPOSIT_WINDOW, DELIVERY_WINDOW, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/
    function testGetProtocolFee() public view {
        assertEq(escrow.getProtocolFee(), FEE);
    }

    function testGetSellerPayout() public view {
        assertEq(escrow.getSellerPayout(), SELLER_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/
    function testDeposit_happyPath() public {
        _deposit();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.AWAITING_DELIVERY));
        assertEq(address(escrow).balance, EXPECTED_AMOUNT);
        assertEq(escrow.s_deliveryDeadline(), block.timestamp + DELIVERY_WINDOW);
    }

    function testDeposit_emitsDeposited() public {
        vm.deal(buyer, EXPECTED_AMOUNT);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit Deposited(buyer, EXPECTED_AMOUNT, block.timestamp + DELIVERY_WINDOW);

        vm.prank(buyer);
        escrow.deposit{ value: EXPECTED_AMOUNT }();
    }

    function testDeposit_succeedsExactlyAtDeadline() public {
        vm.warp(escrow.i_depositDeadline());
        _deposit();
        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.AWAITING_DELIVERY));
    }

    function testDeposit_revertsIfNotBuyer() public {
        vm.deal(seller, EXPECTED_AMOUNT);
        vm.prank(seller);
        vm.expectRevert(Escrow.Escrow__NotBuyer.selector);
        escrow.deposit{ value: EXPECTED_AMOUNT }();
    }

    function testDeposit_revertsIfNotInAwaitingDeposit() public withActiveEscrow {
        vm.deal(buyer, EXPECTED_AMOUNT);
        vm.prank(buyer);
        vm.expectRevert(_wrongState(Escrow.State.AWAITING_DEPOSIT, Escrow.State.AWAITING_DELIVERY));
        escrow.deposit{ value: EXPECTED_AMOUNT }();
    }

    function testDeposit_revertsIfWrongAmount() public {
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
        vm.warp(escrow.i_depositDeadline() + 1);
        vm.deal(buyer, EXPECTED_AMOUNT);
        vm.prank(buyer);
        vm.expectRevert(Escrow.Escrow__DepositWindowExpired.selector);
        escrow.deposit{ value: EXPECTED_AMOUNT }();
    }

    function testDirectEthTransferReverts() public {
        vm.deal(buyer, EXPECTED_AMOUNT);
        vm.prank(buyer);
        (bool success,) = address(escrow).call{ value: EXPECTED_AMOUNT }("");
        assertFalse(success);
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIRM DELIVERY
    //////////////////////////////////////////////////////////////*/
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
        assertEq(escrow.s_pendingWithdrawals(buyer), 0);
    }

    function testConfirmDelivery_emitsEvents() public withActiveEscrow {
        vm.expectEmit(true, false, false, true, address(escrow));
        emit ProtocolFeeCharged(owner, FEE);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit DeliveryConfirmed(seller, SELLER_AMOUNT);

        vm.prank(buyer);
        escrow.confirmDelivery();
    }

    function testConfirmDelivery_allowedAfterDeliveryDeadline() public withActiveEscrow {
        // A late confirmation is still valid as long as nobody has triggered the refund.
        vm.warp(escrow.s_deliveryDeadline() + 1);
        vm.prank(buyer);
        escrow.confirmDelivery();
        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.COMPLETE));
    }

    function testConfirmDelivery_revertsIfNotBuyer() public withActiveEscrow {
        vm.prank(seller);
        vm.expectRevert(Escrow.Escrow__NotBuyer.selector);
        escrow.confirmDelivery();
    }

    function testConfirmDelivery_revertsIfWrongState() public {
        vm.prank(buyer);
        vm.expectRevert(_wrongState(Escrow.State.AWAITING_DELIVERY, Escrow.State.AWAITING_DEPOSIT));
        escrow.confirmDelivery();
    }

    function testConfirmDelivery_revertsIfDisputed() public withDisputedEscrow {
        vm.prank(buyer);
        vm.expectRevert(_wrongState(Escrow.State.AWAITING_DELIVERY, Escrow.State.DISPUTED));
        escrow.confirmDelivery();
    }

    function testConfirmDelivery_revertsIfAlreadyConfirmed() public withCompletedEscrow {
        vm.prank(buyer);
        vm.expectRevert(_wrongState(Escrow.State.AWAITING_DELIVERY, Escrow.State.COMPLETE));
        escrow.confirmDelivery();
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/
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

    function testWithdraw_allPartiesDrainContract() public withCompletedEscrow {
        vm.prank(seller);
        escrow.withdraw();
        vm.prank(owner);
        escrow.withdraw();

        assertEq(address(escrow).balance, 0);
    }

    function testWithdraw_revertsOnSecondCall() public withCompletedEscrow {
        vm.startPrank(seller);
        escrow.withdraw();
        vm.expectRevert(Escrow.Escrow__NothingToWithdraw.selector);
        escrow.withdraw();
        vm.stopPrank();
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

    function testWithdraw_revertsIfDisputed() public withDisputedEscrow {
        vm.prank(buyer);
        vm.expectRevert(Escrow.Escrow__EscrowNotFinalized.selector);
        escrow.withdraw();
    }

    function testWithdraw_emitsWithdrawn() public withCompletedEscrow {
        vm.expectEmit(true, false, false, true, address(escrow));
        emit Withdrawn(seller, SELLER_AMOUNT);

        vm.prank(seller);
        escrow.withdraw();
    }

    function testWithdraw_buyerAfterRefund() public withActiveEscrow {
        vm.warp(escrow.s_deliveryDeadline() + 1);
        escrow.refundOnTimeout();

        vm.prank(buyer);
        escrow.withdraw();

        assertEq(address(buyer).balance, EXPECTED_AMOUNT);
        assertEq(escrow.s_pendingWithdrawals(buyer), 0);
        assertEq(address(escrow).balance, 0);
    }

    function testWithdraw_revertsIfCallFails() public {
        RejectingReceiver rejectingSeller = new RejectingReceiver();
        Escrow escrowWithRejecting =
            _newEscrow(buyer, address(rejectingSeller), arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS);

        vm.deal(buyer, EXPECTED_AMOUNT);
        vm.startPrank(buyer);
        escrowWithRejecting.deposit{ value: EXPECTED_AMOUNT }();
        escrowWithRejecting.confirmDelivery();
        vm.stopPrank();

        vm.prank(address(rejectingSeller));
        vm.expectRevert(Escrow.Escrow__WithdrawalFailed.selector);
        escrowWithRejecting.withdraw();

        // The failed pull only affects the rejecting seller: its credit is preserved and the owner can still withdraw.
        assertEq(escrowWithRejecting.s_pendingWithdrawals(address(rejectingSeller)), SELLER_AMOUNT);
        vm.prank(owner);
        escrowWithRejecting.withdraw();
        assertEq(owner.balance, FEE);
    }

    function testWithdraw_reentrancyCannotDoubleSpend() public {
        ReentrantReceiver attacker = new ReentrantReceiver();
        Escrow target = _newEscrow(buyer, address(attacker), arbiter, owner, EXPECTED_AMOUNT, PROTOCOL_FEE_BPS);
        attacker.setTarget(target);

        vm.deal(buyer, EXPECTED_AMOUNT);
        vm.startPrank(buyer);
        target.deposit{ value: EXPECTED_AMOUNT }();
        target.confirmDelivery();
        vm.stopPrank();

        attacker.attack();

        // The re-entrant call hit NothingToWithdraw (balance already zeroed): the attacker got paid exactly once.
        assertEq(address(attacker).balance, SELLER_AMOUNT);
        assertEq(attacker.reentryAttempts(), 1);
        assertFalse(attacker.reentrySucceeded());
        assertEq(address(target).balance, FEE);
    }

    /*//////////////////////////////////////////////////////////////
                              OPEN DISPUTE
    //////////////////////////////////////////////////////////////*/
    function testOpenDispute_byBuyer() public withActiveEscrow {
        vm.prank(buyer);
        escrow.openDispute();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.DISPUTED));
        assertEq(escrow.s_disputeDeadline(), block.timestamp + DISPUTE_WINDOW);
    }

    function testOpenDispute_bySeller() public withActiveEscrow {
        vm.prank(seller);
        escrow.openDispute();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.DISPUTED));
    }

    function testOpenDispute_emitsDisputeOpened() public withActiveEscrow {
        vm.expectEmit(true, false, false, true, address(escrow));
        emit DisputeOpened(buyer, block.timestamp + DISPUTE_WINDOW);

        vm.prank(buyer);
        escrow.openDispute();
    }

    function testOpenDispute_succeedsExactlyAtDeliveryDeadline() public withActiveEscrow {
        vm.warp(escrow.s_deliveryDeadline());
        vm.prank(seller);
        escrow.openDispute();
        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.DISPUTED));
    }

    function testOpenDispute_revertsAfterDeliveryDeadline() public withActiveEscrow {
        // Prevents a seller from front-running refundOnTimeout() to freeze the buyer's funds.
        vm.warp(escrow.s_deliveryDeadline() + 1);
        vm.prank(seller);
        vm.expectRevert(Escrow.Escrow__DeliveryWindowExpired.selector);
        escrow.openDispute();
    }

    function testOpenDispute_revertsIfNotSellerOrBuyer() public withActiveEscrow {
        vm.prank(arbiter);
        vm.expectRevert(Escrow.Escrow__NotSellerOrBuyer.selector);
        escrow.openDispute();
    }

    function testOpenDispute_revertsIfWrongState() public {
        vm.prank(buyer);
        vm.expectRevert(_wrongState(Escrow.State.AWAITING_DELIVERY, Escrow.State.AWAITING_DEPOSIT));
        escrow.openDispute();
    }

    function testOpenDispute_revertsIfAlreadyDisputed() public withDisputedEscrow {
        vm.prank(seller);
        vm.expectRevert(_wrongState(Escrow.State.AWAITING_DELIVERY, Escrow.State.DISPUTED));
        escrow.openDispute();
    }

    /*//////////////////////////////////////////////////////////////
                            RESOLVE DISPUTE
    //////////////////////////////////////////////////////////////*/
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
        assertEq(escrow.s_pendingWithdrawals(buyer), 0);
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

    function testResolveDispute_releaseToSeller_emitsDisputeResolved() public withDisputedEscrow {
        vm.expectEmit(true, false, false, true, address(escrow));
        emit DisputeResolved(seller, true, SELLER_AMOUNT);

        vm.prank(arbiter);
        escrow.resolveDispute(true);
    }

    function testResolveDispute_refundBuyer_emitsDisputeResolved() public withDisputedEscrow {
        vm.expectEmit(true, false, false, true, address(escrow));
        emit DisputeResolved(buyer, false, EXPECTED_AMOUNT);

        vm.prank(arbiter);
        escrow.resolveDispute(false);
    }

    function testResolveDispute_succeedsExactlyAtDisputeDeadline() public withDisputedEscrow {
        vm.warp(escrow.s_disputeDeadline());
        vm.prank(arbiter);
        escrow.resolveDispute(true);
        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.COMPLETE));
    }

    function testResolveDispute_revertsAfterDisputeDeadline() public withDisputedEscrow {
        vm.warp(escrow.s_disputeDeadline() + 1);
        vm.prank(arbiter);
        vm.expectRevert(Escrow.Escrow__DisputeWindowExpired.selector);
        escrow.resolveDispute(true);
    }

    function testResolveDispute_revertsIfNotArbiter() public withDisputedEscrow {
        vm.prank(seller);
        vm.expectRevert(Escrow.Escrow__NotArbiter.selector);
        escrow.resolveDispute(true);
    }

    function testResolveDispute_revertsIfWrongState() public {
        vm.prank(arbiter);
        vm.expectRevert(_wrongState(Escrow.State.DISPUTED, Escrow.State.AWAITING_DEPOSIT));
        escrow.resolveDispute(true);
    }

    /*//////////////////////////////////////////////////////////////
                           REFUND ON TIMEOUT
    //////////////////////////////////////////////////////////////*/
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

        vm.expectEmit(true, false, false, true, address(escrow));
        emit Refunded(buyer, EXPECTED_AMOUNT);

        escrow.refundOnTimeout();
    }

    function testRefundOnTimeout_anyoneCanCall() public withActiveEscrow {
        vm.warp(escrow.s_deliveryDeadline() + 1);

        vm.prank(makeAddr("randomCaller"));
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
        vm.expectRevert(_wrongState(Escrow.State.AWAITING_DELIVERY, Escrow.State.AWAITING_DEPOSIT));
        escrow.refundOnTimeout();
    }

    function testRefundOnTimeout_revertsIfDisputed() public withDisputedEscrow {
        vm.warp(escrow.s_deliveryDeadline() + 1);
        vm.expectRevert(_wrongState(Escrow.State.AWAITING_DELIVERY, Escrow.State.DISPUTED));
        escrow.refundOnTimeout();
    }

    /*//////////////////////////////////////////////////////////////
                       REFUND ON DISPUTE TIMEOUT
    //////////////////////////////////////////////////////////////*/
    function testRefundOnDisputeTimeout_happyPath() public withDisputedEscrow {
        vm.warp(escrow.s_disputeDeadline() + 1);

        vm.prank(makeAddr("randomCaller"));
        escrow.refundOnDisputeTimeout();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.REFUNDED));
        assertEq(escrow.s_pendingWithdrawals(buyer), EXPECTED_AMOUNT);
        assertEq(escrow.s_pendingWithdrawals(seller), 0);
        assertEq(escrow.s_pendingWithdrawals(owner), 0);
    }

    function testRefundOnDisputeTimeout_emitsRefunded() public withDisputedEscrow {
        vm.warp(escrow.s_disputeDeadline() + 1);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit Refunded(buyer, EXPECTED_AMOUNT);

        escrow.refundOnDisputeTimeout();
    }

    function testRefundOnDisputeTimeout_buyerCanWithdraw() public withDisputedEscrow {
        vm.warp(escrow.s_disputeDeadline() + 1);
        escrow.refundOnDisputeTimeout();

        vm.prank(buyer);
        escrow.withdraw();

        assertEq(buyer.balance, EXPECTED_AMOUNT);
        assertEq(address(escrow).balance, 0);
    }

    function testRefundOnDisputeTimeout_revertsIfBeforeDeadline() public withDisputedEscrow {
        vm.warp(escrow.s_disputeDeadline());
        vm.expectRevert(Escrow.Escrow__DisputeWindowNotExpired.selector);
        escrow.refundOnDisputeTimeout();
    }

    function testRefundOnDisputeTimeout_revertsIfNotDisputed() public withActiveEscrow {
        vm.expectRevert(_wrongState(Escrow.State.DISPUTED, Escrow.State.AWAITING_DELIVERY));
        escrow.refundOnDisputeTimeout();
    }

    function testRefundOnDisputeTimeout_revertsIfAlreadyResolved() public withDisputedEscrow {
        vm.prank(arbiter);
        escrow.resolveDispute(true);

        vm.warp(escrow.s_disputeDeadline() + 1);
        vm.expectRevert(_wrongState(Escrow.State.DISPUTED, Escrow.State.COMPLETE));
        escrow.refundOnDisputeTimeout();
    }
}
