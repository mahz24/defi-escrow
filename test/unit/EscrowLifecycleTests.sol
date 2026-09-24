// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Escrow } from "../../src/Escrow.sol";
import { EscrowTestBase } from "../utils/EscrowTestBase.sol";

/// @notice Asset-agnostic lifecycle tests. Inherited by `EscrowEthTest` and `EscrowErc20Test`, so every
///         test here runs once with native ETH and once with an ERC-20.
abstract contract EscrowLifecycleTests is EscrowTestBase {
    event Deposited(address indexed buyer, uint256 amount, uint256 deliveryDeadline);
    event DeliveryConfirmed(address indexed seller, uint256 amount);
    event ProtocolFeeCharged(address indexed feeRecipient, uint256 fee);
    event DisputeOpened(address indexed openedBy, uint256 disputeDeadline);
    event DisputeResolved(address indexed recipient, bool releaseToSeller, uint256 amount);
    event Refunded(address indexed buyer, uint256 amount);
    event Withdrawn(address indexed account, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                             INITIAL STATE
    //////////////////////////////////////////////////////////////*/
    function testInit_setsTerms() public view {
        assertEq(escrow.s_buyer(), buyer);
        assertEq(escrow.s_seller(), seller);
        assertEq(escrow.s_arbiter(), arbiter);
        assertEq(escrow.s_feeRecipient(), feeRecipient);
        assertEq(escrow.s_token(), token);
        assertEq(escrow.isNative(), _isNative());
        assertEq(escrow.s_amount(), _amount());
        assertEq(escrow.s_protocolFeeBps(), FEE_BPS);
        assertEq(escrow.s_depositDeadline(), block.timestamp + DEPOSIT_WINDOW);
        assertEq(escrow.s_deliveryWindow(), DELIVERY_WINDOW);
        assertEq(escrow.s_disputeWindow(), DISPUTE_WINDOW);
    }

    function testInit_setsInitialState() public view {
        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.AWAITING_DEPOSIT));
        assertEq(escrow.s_deliveryDeadline(), 0);
        assertEq(escrow.s_disputeDeadline(), 0);
    }

    function testViews_feeAndPayout() public view {
        assertEq(escrow.getProtocolFee(), _fee());
        assertEq(escrow.getSellerPayout(), _sellerAmount());
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/
    function testDeposit_happyPath() public {
        _deposit();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.AWAITING_DELIVERY));
        assertEq(_balance(address(escrow)), _amount());
        assertEq(_balance(buyer), 0);
        assertEq(escrow.s_deliveryDeadline(), block.timestamp + DELIVERY_WINDOW);
    }

    function testDeposit_emitsDeposited() public {
        _fund(buyer, _amount());
        vm.startPrank(buyer);
        if (!_isNative()) IERC20(token).approve(address(escrow), _amount());

        vm.expectEmit(true, false, false, true, address(escrow));
        emit Deposited(buyer, _amount(), block.timestamp + DELIVERY_WINDOW);
        escrow.deposit{ value: _isNative() ? _amount() : 0 }();
        vm.stopPrank();
    }

    function testDeposit_succeedsExactlyAtDeadline() public {
        vm.warp(escrow.s_depositDeadline());
        _deposit();
        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.AWAITING_DELIVERY));
    }

    function testDeposit_revertsIfNotBuyer() public {
        vm.prank(seller);
        vm.expectRevert(Escrow.Escrow__NotBuyer.selector);
        escrow.deposit();
    }

    function testDeposit_revertsIfAlreadyDeposited() public withActiveEscrow {
        vm.prank(buyer);
        vm.expectRevert(_wrongState(Escrow.State.AWAITING_DEPOSIT, Escrow.State.AWAITING_DELIVERY));
        escrow.deposit();
    }

    function testDeposit_revertsAfterDeadline() public {
        vm.warp(escrow.s_depositDeadline() + 1);
        vm.prank(buyer);
        vm.expectRevert(Escrow.Escrow__DepositWindowExpired.selector);
        escrow.deposit();
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIRM DELIVERY
    //////////////////////////////////////////////////////////////*/
    function testConfirmDelivery_setsComplete() public withActiveEscrow {
        vm.prank(buyer);
        escrow.confirmDelivery();
        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.COMPLETE));
    }

    function testConfirmDelivery_creditsSellerAndFeeRecipient() public withActiveEscrow {
        vm.prank(buyer);
        escrow.confirmDelivery();

        assertEq(escrow.s_pendingWithdrawals(seller), _sellerAmount());
        assertEq(escrow.s_pendingWithdrawals(feeRecipient), _fee());
        assertEq(escrow.s_pendingWithdrawals(buyer), 0);
    }

    function testConfirmDelivery_emitsEvents() public withActiveEscrow {
        vm.expectEmit(true, false, false, true, address(escrow));
        emit ProtocolFeeCharged(feeRecipient, _fee());
        vm.expectEmit(true, false, false, true, address(escrow));
        emit DeliveryConfirmed(seller, _sellerAmount());

        vm.prank(buyer);
        escrow.confirmDelivery();
    }

    function testConfirmDelivery_allowedAfterDeliveryDeadline() public withActiveEscrow {
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

    function testConfirmDelivery_revertsBeforeDeposit() public {
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
    function testWithdraw_seller() public withCompletedEscrow {
        vm.prank(seller);
        escrow.withdraw();

        assertEq(_balance(seller), _sellerAmount());
        assertEq(escrow.s_pendingWithdrawals(seller), 0);
        assertEq(_balance(address(escrow)), _fee());
    }

    function testWithdraw_feeRecipient() public withCompletedEscrow {
        vm.prank(feeRecipient);
        escrow.withdraw();

        assertEq(_balance(feeRecipient), _fee());
        assertEq(escrow.s_pendingWithdrawals(feeRecipient), 0);
    }

    function testWithdraw_allPartiesDrainEscrow() public withCompletedEscrow {
        vm.prank(seller);
        escrow.withdraw();
        vm.prank(feeRecipient);
        escrow.withdraw();

        assertEq(_balance(address(escrow)), 0);
    }

    function testWithdraw_buyerAfterRefund() public withActiveEscrow {
        vm.warp(escrow.s_deliveryDeadline() + 1);
        escrow.refundOnTimeout();

        vm.prank(buyer);
        escrow.withdraw();

        assertEq(_balance(buyer), _amount());
        assertEq(_balance(address(escrow)), 0);
    }

    function testWithdraw_emitsWithdrawn() public withCompletedEscrow {
        vm.expectEmit(true, true, false, true, address(escrow));
        emit Withdrawn(seller, seller, _sellerAmount());

        vm.prank(seller);
        escrow.withdraw();
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

    function testWithdraw_revertsIfNotFinalized() public withActiveEscrow {
        vm.prank(seller);
        vm.expectRevert(Escrow.Escrow__EscrowNotFinalized.selector);
        escrow.withdraw();
    }

    function testWithdraw_revertsIfDisputed() public withDisputedEscrow {
        vm.prank(buyer);
        vm.expectRevert(Escrow.Escrow__EscrowNotFinalized.selector);
        escrow.withdraw();
    }

    function testWithdrawTo_sendsToAnotherAddress() public withCompletedEscrow {
        address coldWallet = makeAddr("coldWallet");

        vm.expectEmit(true, true, false, true, address(escrow));
        emit Withdrawn(seller, coldWallet, _sellerAmount());
        vm.prank(seller);
        escrow.withdrawTo(coldWallet);

        assertEq(_balance(coldWallet), _sellerAmount());
        assertEq(_balance(seller), 0);
        assertEq(escrow.s_pendingWithdrawals(seller), 0);
    }

    function testWithdrawTo_revertsForZeroAddress() public withCompletedEscrow {
        vm.prank(seller);
        vm.expectRevert(Escrow.Escrow__InvalidAddress.selector);
        escrow.withdrawTo(address(0));
    }

    function testWithdrawTo_cannotPullSomeoneElsesCredit() public withCompletedEscrow {
        // withdrawTo only moves msg.sender's own credit — an outsider has nothing to redirect.
        address thief = makeAddr("thief");
        vm.prank(thief);
        vm.expectRevert(Escrow.Escrow__NothingToWithdraw.selector);
        escrow.withdrawTo(thief);
        assertEq(escrow.s_pendingWithdrawals(seller), _sellerAmount());
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

    function testOpenDispute_revertsBeforeDeposit() public {
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
    function testResolveDispute_releaseToSeller() public withDisputedEscrow {
        vm.expectEmit(true, false, false, true, address(escrow));
        emit DisputeResolved(seller, true, _sellerAmount());

        vm.prank(arbiter);
        escrow.resolveDispute(true);

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.COMPLETE));
        assertEq(escrow.s_pendingWithdrawals(seller), _sellerAmount());
        assertEq(escrow.s_pendingWithdrawals(feeRecipient), _fee());
        assertEq(escrow.s_pendingWithdrawals(buyer), 0);
    }

    function testResolveDispute_refundBuyer() public withDisputedEscrow {
        vm.expectEmit(true, false, false, true, address(escrow));
        emit DisputeResolved(buyer, false, _amount());

        vm.prank(arbiter);
        escrow.resolveDispute(false);

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.REFUNDED));
        assertEq(escrow.s_pendingWithdrawals(buyer), _amount());
        assertEq(escrow.s_pendingWithdrawals(seller), 0);
        assertEq(escrow.s_pendingWithdrawals(feeRecipient), 0);
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

    function testResolveDispute_revertsIfNotDisputed() public withActiveEscrow {
        vm.prank(arbiter);
        vm.expectRevert(_wrongState(Escrow.State.DISPUTED, Escrow.State.AWAITING_DELIVERY));
        escrow.resolveDispute(true);
    }

    /*//////////////////////////////////////////////////////////////
                               TIMEOUTS
    //////////////////////////////////////////////////////////////*/
    function testRefundOnTimeout_anyoneCanRefundAfterDeadline() public withActiveEscrow {
        vm.warp(escrow.s_deliveryDeadline() + 1);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit Refunded(buyer, _amount());
        vm.prank(makeAddr("randomCaller"));
        escrow.refundOnTimeout();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.REFUNDED));
        assertEq(escrow.s_pendingWithdrawals(buyer), _amount());
        assertEq(escrow.s_pendingWithdrawals(seller), 0);
        assertEq(escrow.s_pendingWithdrawals(feeRecipient), 0);
    }

    function testRefundOnTimeout_revertsAtDeadline() public withActiveEscrow {
        vm.warp(escrow.s_deliveryDeadline());
        vm.expectRevert(Escrow.Escrow__DeliveryWindowNotExpired.selector);
        escrow.refundOnTimeout();
    }

    function testRefundOnTimeout_revertsBeforeDeposit() public {
        vm.expectRevert(_wrongState(Escrow.State.AWAITING_DELIVERY, Escrow.State.AWAITING_DEPOSIT));
        escrow.refundOnTimeout();
    }

    function testRefundOnTimeout_revertsIfDisputed() public withDisputedEscrow {
        vm.warp(escrow.s_deliveryDeadline() + 1);
        vm.expectRevert(_wrongState(Escrow.State.AWAITING_DELIVERY, Escrow.State.DISPUTED));
        escrow.refundOnTimeout();
    }

    function testRefundOnDisputeTimeout_anyoneCanRefundAfterDeadline() public withDisputedEscrow {
        vm.warp(escrow.s_disputeDeadline() + 1);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit Refunded(buyer, _amount());
        vm.prank(makeAddr("randomCaller"));
        escrow.refundOnDisputeTimeout();

        assertEq(uint256(escrow.s_state()), uint256(Escrow.State.REFUNDED));
        assertEq(escrow.s_pendingWithdrawals(buyer), _amount());

        vm.prank(buyer);
        escrow.withdraw();
        assertEq(_balance(buyer), _amount());
        assertEq(_balance(address(escrow)), 0);
    }

    function testRefundOnDisputeTimeout_revertsAtDeadline() public withDisputedEscrow {
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
