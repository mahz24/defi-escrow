// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Test } from "forge-std/Test.sol";
import { Escrow } from "../../src/Escrow.sol";

/// @notice Property-based tests: each test states a property that must hold for *any* input.
contract EscrowFuzzTest is Test {
    uint256 constant DEPOSIT_WINDOW = 1 days;
    uint256 constant DELIVERY_WINDOW = 7 days;
    uint256 constant DISPUTE_WINDOW = 3 days;
    uint256 constant MAX_AMOUNT = 1e30; // far above total ETH supply

    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address arbiter = makeAddr("arbiter");
    address owner = makeAddr("owner");

    function _deploy(uint256 amount, uint256 feeBps) internal returns (Escrow) {
        return
            new Escrow(buyer, seller, arbiter, owner, amount, feeBps, DEPOSIT_WINDOW, DELIVERY_WINDOW, DISPUTE_WINDOW);
    }

    function _deployAndDeposit(uint256 amount, uint256 feeBps) internal returns (Escrow escrow) {
        escrow = _deploy(amount, feeBps);
        vm.deal(buyer, amount);
        vm.prank(buyer);
        escrow.deposit{ value: amount }();
    }

    function _isRole(address a) internal view returns (bool) {
        return a == buyer || a == seller || a == arbiter || a == owner;
    }

    /// Property: seller payout + fee always equals the deposit, and the fee never exceeds the 5% cap.
    function testFuzz_feeSplitIsExactAndCapped(uint256 amount, uint256 feeBps) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        feeBps = bound(feeBps, 0, 500);
        Escrow escrow = _deployAndDeposit(amount, feeBps);

        vm.prank(buyer);
        escrow.confirmDelivery();

        uint256 sellerCredit = escrow.s_pendingWithdrawals(seller);
        uint256 ownerCredit = escrow.s_pendingWithdrawals(owner);
        assertEq(sellerCredit + ownerCredit, amount);
        assertLe(ownerCredit, amount * 500 / 10_000);
        assertEq(ownerCredit, escrow.getProtocolFee());
        assertEq(sellerCredit, escrow.getSellerPayout());
    }

    /// Property: whatever the arbiter decides, every wei is credited to exactly one outcome and fully withdrawable.
    function testFuzz_resolveDisputeConservesFunds(uint256 amount, uint256 feeBps, bool releaseToSeller) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        feeBps = bound(feeBps, 0, 500);
        Escrow escrow = _deployAndDeposit(amount, feeBps);

        vm.prank(seller);
        escrow.openDispute();
        vm.prank(arbiter);
        escrow.resolveDispute(releaseToSeller);

        if (releaseToSeller) {
            assertEq(escrow.s_pendingWithdrawals(buyer), 0);
            vm.prank(seller);
            escrow.withdraw();
            if (escrow.s_pendingWithdrawals(owner) > 0) {
                vm.prank(owner);
                escrow.withdraw();
            }
            assertEq(seller.balance + owner.balance, amount);
        } else {
            assertEq(escrow.s_pendingWithdrawals(seller), 0);
            assertEq(escrow.s_pendingWithdrawals(owner), 0);
            vm.prank(buyer);
            escrow.withdraw();
            assertEq(buyer.balance, amount);
        }
        assertEq(address(escrow).balance, 0);
    }

    /// Property: any value other than the exact expected amount is rejected.
    function testFuzz_depositRejectsWrongValue(uint256 amount, uint256 value) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        value = bound(value, 0, MAX_AMOUNT);
        vm.assume(value != amount);
        Escrow escrow = _deploy(amount, 100);

        vm.deal(buyer, value);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.Escrow__WrongPaymentAmount.selector, value, amount));
        escrow.deposit{ value: value }();
    }

    /// Property: only the buyer can deposit.
    function testFuzz_onlyBuyerCanDeposit(address caller) public {
        vm.assume(caller != buyer);
        Escrow escrow = _deploy(1 ether, 100);

        vm.deal(caller, 1 ether);
        vm.prank(caller);
        vm.expectRevert(Escrow.Escrow__NotBuyer.selector);
        escrow.deposit{ value: 1 ether }();
    }

    /// Property: deposit succeeds iff it happens on or before the deposit deadline.
    function testFuzz_depositDeadline(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 365 days);
        Escrow escrow = _deploy(1 ether, 100);
        vm.warp(block.timestamp + elapsed);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        if (elapsed > DEPOSIT_WINDOW) vm.expectRevert(Escrow.Escrow__DepositWindowExpired.selector);
        escrow.deposit{ value: 1 ether }();
    }

    /// Property: the delivery timeout refund is available iff the delivery deadline has strictly passed.
    function testFuzz_refundOnTimeoutOnlyAfterDeadline(uint256 elapsed, address caller) public {
        elapsed = bound(elapsed, 0, 365 days);
        Escrow escrow = _deployAndDeposit(1 ether, 100);
        vm.warp(block.timestamp + elapsed);

        vm.prank(caller);
        if (elapsed <= DELIVERY_WINDOW) vm.expectRevert(Escrow.Escrow__DeliveryWindowNotExpired.selector);
        escrow.refundOnTimeout();
    }

    /// Property: the dispute timeout refund is available iff the dispute deadline has strictly passed.
    function testFuzz_refundOnDisputeTimeoutOnlyAfterDeadline(uint256 elapsed, address caller) public {
        elapsed = bound(elapsed, 0, 365 days);
        Escrow escrow = _deployAndDeposit(1 ether, 100);
        vm.prank(buyer);
        escrow.openDispute();
        vm.warp(block.timestamp + elapsed);

        vm.prank(caller);
        if (elapsed <= DISPUTE_WINDOW) vm.expectRevert(Escrow.Escrow__DisputeWindowNotExpired.selector);
        escrow.refundOnDisputeTimeout();
    }

    /// Property: nobody except the arbiter can resolve a dispute.
    function testFuzz_onlyArbiterCanResolve(address caller, bool releaseToSeller) public {
        vm.assume(caller != arbiter);
        Escrow escrow = _deployAndDeposit(1 ether, 100);
        vm.prank(buyer);
        escrow.openDispute();

        vm.prank(caller);
        vm.expectRevert(Escrow.Escrow__NotArbiter.selector);
        escrow.resolveDispute(releaseToSeller);
    }

    /// Property: outsiders can never open a dispute or confirm delivery.
    function testFuzz_outsidersCannotActOnEscrow(address caller) public {
        vm.assume(!_isRole(caller));
        Escrow escrow = _deployAndDeposit(1 ether, 100);

        vm.startPrank(caller);
        vm.expectRevert(Escrow.Escrow__NotSellerOrBuyer.selector);
        escrow.openDispute();
        vm.expectRevert(Escrow.Escrow__NotBuyer.selector);
        escrow.confirmDelivery();
        vm.stopPrank();
    }

    /// Property: the constructor rejects any fee above the cap.
    function testFuzz_constructorRejectsFeeAboveCap(uint256 feeBps) public {
        feeBps = bound(feeBps, 501, type(uint256).max);
        vm.expectRevert(Escrow.Escrow__InvalidProtocolFee.selector);
        _deploy(1 ether, feeBps);
    }
}
