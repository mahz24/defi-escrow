// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Escrow } from "../../src/Escrow.sol";
import { EscrowFactory } from "../../src/EscrowFactory.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Shared fixture: a factory, one escrow, and asset-agnostic helpers so the same test body can run
///         against native ETH and against ERC-20 tokens.
abstract contract EscrowTestBase is Test {
    EscrowFactory factory;
    Escrow escrow;
    address token; // address(0) = native ETH

    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant BPS_DIVISOR = 10_000;
    uint256 constant DEPOSIT_WINDOW = 1 days;
    uint256 constant DELIVERY_WINDOW = 7 days;
    uint256 constant DISPUTE_WINDOW = 3 days;

    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address arbiter = makeAddr("arbiter");
    address feeRecipient = makeAddr("feeRecipient");
    address factoryOwner = makeAddr("factoryOwner");

    uint256 private saltNonce;

    /// @dev Token the suite runs against. Return address(0) for native ETH.
    function _deployToken() internal virtual returns (address);

    /// @dev Escrow amount in the asset's base units.
    function _amount() internal view virtual returns (uint256);

    function setUp() public virtual {
        token = _deployToken();
        factory = new EscrowFactory(factoryOwner, feeRecipient, FEE_BPS);
        escrow = _create(_params());
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function _isNative() internal view returns (bool) {
        return token == address(0);
    }

    function _fee() internal view returns (uint256) {
        return _amount() * FEE_BPS / BPS_DIVISOR;
    }

    function _sellerAmount() internal view returns (uint256) {
        return _amount() - _fee();
    }

    function _params() internal view returns (Escrow.EscrowParams memory) {
        return Escrow.EscrowParams({
            buyer: buyer,
            seller: seller,
            arbiter: arbiter,
            token: token,
            amount: _amount(),
            depositWindow: DEPOSIT_WINDOW,
            deliveryWindow: DELIVERY_WINDOW,
            disputeWindow: DISPUTE_WINDOW
        });
    }

    function _create(Escrow.EscrowParams memory p) internal returns (Escrow) {
        return Escrow(factory.createEscrow(p, bytes32(saltNonce++)));
    }

    function _fund(address who, uint256 amount) internal {
        if (_isNative()) vm.deal(who, who.balance + amount);
        else IMintable(token).mint(who, amount);
    }

    function _balance(address who) internal view returns (uint256) {
        return _isNative() ? who.balance : IERC20(token).balanceOf(who);
    }

    /// @dev Funds the buyer, approves if needed and deposits into `target`.
    function _depositInto(Escrow target) internal {
        uint256 amount = target.s_amount();
        _fund(buyer, amount);
        vm.startPrank(buyer);
        if (_isNative()) {
            target.deposit{ value: amount }();
        } else {
            IERC20(token).approve(address(target), amount);
            target.deposit();
        }
        vm.stopPrank();
    }

    function _deposit() internal {
        _depositInto(escrow);
    }

    function _wrongState(Escrow.State expected, Escrow.State current) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Escrow.Escrow__WrongState.selector, expected, current);
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
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
}
