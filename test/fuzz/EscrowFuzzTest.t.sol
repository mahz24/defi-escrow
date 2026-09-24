// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Escrow } from "../../src/Escrow.sol";
import { EscrowFactory } from "../../src/EscrowFactory.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Property-based tests: each test states a property that must hold for *any* input.
///         Where it matters, the asset (ETH or ERC-20) is itself a fuzzed input.
contract EscrowFuzzTest is Test {
    uint256 constant DEPOSIT_WINDOW = 1 days;
    uint256 constant DELIVERY_WINDOW = 7 days;
    uint256 constant DISPUTE_WINDOW = 3 days;
    uint256 constant MAX_AMOUNT = 1e30; // far above total ETH supply / typical token supplies

    EscrowFactory factory;
    MockERC20 usd;

    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address arbiter = makeAddr("arbiter");
    address feeRecipient = makeAddr("feeRecipient");
    address factoryOwner = makeAddr("factoryOwner");

    uint256 saltNonce;

    function setUp() public {
        factory = new EscrowFactory(factoryOwner, feeRecipient, 0);
        usd = new MockERC20("Mock USD", "mUSD", 6);
    }

    function _deploy(uint256 amount, uint256 feeBps, bool useToken) internal returns (Escrow) {
        vm.prank(factoryOwner);
        factory.setProtocolFee(feeBps);
        Escrow.EscrowParams memory p = Escrow.EscrowParams({
            buyer: buyer,
            seller: seller,
            arbiter: arbiter,
            token: useToken ? address(usd) : address(0),
            amount: amount,
            depositWindow: DEPOSIT_WINDOW,
            deliveryWindow: DELIVERY_WINDOW,
            disputeWindow: DISPUTE_WINDOW
        });
        return Escrow(factory.createEscrow(p, bytes32(saltNonce++)));
    }

    function _deployAndDeposit(uint256 amount, uint256 feeBps, bool useToken) internal returns (Escrow escrow) {
        escrow = _deploy(amount, feeBps, useToken);
        vm.startPrank(buyer);
        if (useToken) {
            usd.mint(buyer, amount);
            usd.approve(address(escrow), amount);
            escrow.deposit();
        } else {
            vm.deal(buyer, amount);
            escrow.deposit{ value: amount }();
        }
        vm.stopPrank();
    }

    function _balance(address who, bool useToken) internal view returns (uint256) {
        return useToken ? usd.balanceOf(who) : who.balance;
    }

    function _isRole(address a) internal view returns (bool) {
        return a == buyer || a == seller || a == arbiter || a == feeRecipient;
    }

    /// Property: seller payout + fee always equals the deposit, and the fee never exceeds the 5% cap.
    function testFuzz_feeSplitIsExactAndCapped(uint256 amount, uint256 feeBps, bool useToken) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        feeBps = bound(feeBps, 0, 500);
        Escrow escrow = _deployAndDeposit(amount, feeBps, useToken);

        vm.prank(buyer);
        escrow.confirmDelivery();

        uint256 sellerCredit = escrow.s_pendingWithdrawals(seller);
        uint256 feeCredit = escrow.s_pendingWithdrawals(feeRecipient);
        assertEq(sellerCredit + feeCredit, amount);
        assertLe(feeCredit, amount * 500 / 10_000);
        assertEq(feeCredit, escrow.getProtocolFee());
        assertEq(sellerCredit, escrow.getSellerPayout());
    }

    /// Property: whatever the arbiter decides, every unit is credited to exactly one outcome and fully withdrawable.
    function testFuzz_resolveDisputeConservesFunds(uint256 amount, uint256 feeBps, bool releaseToSeller, bool useToken)
        public
    {
        amount = bound(amount, 1, MAX_AMOUNT);
        feeBps = bound(feeBps, 0, 500);
        Escrow escrow = _deployAndDeposit(amount, feeBps, useToken);

        vm.prank(seller);
        escrow.openDispute();
        vm.prank(arbiter);
        escrow.resolveDispute(releaseToSeller);

        if (releaseToSeller) {
            assertEq(escrow.s_pendingWithdrawals(buyer), 0);
            vm.prank(seller);
            escrow.withdraw();
            if (escrow.s_pendingWithdrawals(feeRecipient) > 0) {
                vm.prank(feeRecipient);
                escrow.withdraw();
            }
            assertEq(_balance(seller, useToken) + _balance(feeRecipient, useToken), amount);
        } else {
            assertEq(escrow.s_pendingWithdrawals(seller), 0);
            assertEq(escrow.s_pendingWithdrawals(feeRecipient), 0);
            vm.prank(buyer);
            escrow.withdraw();
            assertEq(_balance(buyer, useToken), amount);
        }
        assertEq(_balance(address(escrow), useToken), 0);
    }

    /// Property: an ETH escrow rejects any value other than the exact amount.
    function testFuzz_ethDepositRejectsWrongValue(uint256 amount, uint256 value) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        value = bound(value, 0, MAX_AMOUNT);
        vm.assume(value != amount);
        Escrow escrow = _deploy(amount, 100, false);

        vm.deal(buyer, value);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.Escrow__WrongPaymentAmount.selector, value, amount));
        escrow.deposit{ value: value }();
    }

    /// Property: a token escrow rejects any attached ETH.
    function testFuzz_tokenDepositRejectsAnyEth(uint256 value) public {
        value = bound(value, 1, MAX_AMOUNT);
        Escrow escrow = _deploy(1000e6, 100, true);

        vm.deal(buyer, value);
        vm.prank(buyer);
        vm.expectRevert(Escrow.Escrow__UnexpectedEth.selector);
        escrow.deposit{ value: value }();
    }

    /// Property: only the buyer can deposit.
    function testFuzz_onlyBuyerCanDeposit(address caller, bool useToken) public {
        vm.assume(caller != buyer);
        Escrow escrow = _deploy(1 ether, 100, useToken);

        vm.prank(caller);
        vm.expectRevert(Escrow.Escrow__NotBuyer.selector);
        escrow.deposit();
    }

    /// Property: deposit succeeds iff it happens on or before the deposit deadline.
    function testFuzz_depositDeadline(uint256 elapsed, bool useToken) public {
        elapsed = bound(elapsed, 0, 365 days);
        Escrow escrow = _deploy(1 ether, 100, useToken);
        vm.warp(block.timestamp + elapsed);

        if (useToken) {
            usd.mint(buyer, 1 ether);
            vm.prank(buyer);
            usd.approve(address(escrow), 1 ether);
        } else {
            vm.deal(buyer, 1 ether);
        }

        vm.prank(buyer);
        if (elapsed > DEPOSIT_WINDOW) vm.expectRevert(Escrow.Escrow__DepositWindowExpired.selector);
        escrow.deposit{ value: useToken ? 0 : 1 ether }();
    }

    /// Property: the delivery timeout refund is available iff the delivery deadline has strictly passed.
    function testFuzz_refundOnTimeoutOnlyAfterDeadline(uint256 elapsed, address caller) public {
        elapsed = bound(elapsed, 0, 365 days);
        Escrow escrow = _deployAndDeposit(1 ether, 100, false);
        vm.warp(block.timestamp + elapsed);

        vm.prank(caller);
        if (elapsed <= DELIVERY_WINDOW) vm.expectRevert(Escrow.Escrow__DeliveryWindowNotExpired.selector);
        escrow.refundOnTimeout();
    }

    /// Property: the dispute timeout refund is available iff the dispute deadline has strictly passed.
    function testFuzz_refundOnDisputeTimeoutOnlyAfterDeadline(uint256 elapsed, address caller) public {
        elapsed = bound(elapsed, 0, 365 days);
        Escrow escrow = _deployAndDeposit(1 ether, 100, false);
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
        Escrow escrow = _deployAndDeposit(1 ether, 100, false);
        vm.prank(buyer);
        escrow.openDispute();

        vm.prank(caller);
        vm.expectRevert(Escrow.Escrow__NotArbiter.selector);
        escrow.resolveDispute(releaseToSeller);
    }

    /// Property: outsiders can never open a dispute or confirm delivery.
    function testFuzz_outsidersCannotActOnEscrow(address caller) public {
        vm.assume(!_isRole(caller));
        Escrow escrow = _deployAndDeposit(1 ether, 100, false);

        vm.startPrank(caller);
        vm.expectRevert(Escrow.Escrow__NotSellerOrBuyer.selector);
        escrow.openDispute();
        vm.expectRevert(Escrow.Escrow__NotBuyer.selector);
        escrow.confirmDelivery();
        vm.stopPrank();
    }

    /// Property: the factory rejects any fee above the cap.
    function testFuzz_factoryRejectsFeeAboveCap(uint256 feeBps) public {
        feeBps = bound(feeBps, 501, type(uint256).max);
        vm.prank(factoryOwner);
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidProtocolFee.selector);
        factory.setProtocolFee(feeBps);
    }

    /// Property: createEscrow always deploys to the address predicted for (creator, salt).
    function testFuzz_predictedAddressMatches(address creator, bytes32 salt) public {
        vm.assume(creator != address(0));
        address predicted = factory.predictEscrowAddress(creator, salt);
        Escrow.EscrowParams memory p = Escrow.EscrowParams({
            buyer: buyer,
            seller: seller,
            arbiter: arbiter,
            token: address(0),
            amount: 1 ether,
            depositWindow: DEPOSIT_WINDOW,
            deliveryWindow: DELIVERY_WINDOW,
            disputeWindow: DISPUTE_WINDOW
        });

        vm.prank(creator);
        assertEq(factory.createEscrow(p, salt), predicted);
    }
}
