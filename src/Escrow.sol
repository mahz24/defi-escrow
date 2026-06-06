// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

contract Escrow {
    // ERRORS
    error Escrow__InvalidAddress();
    error Escrow__SameSellerAndBuyer();
    error Escrow__SameBuyerAndArbiter();
    error Escrow__SameSellerAndArbiter();
    error Escrow__InvalidExpectedAmount();
    error Escrow__InvalidProtocolFee();
    error Escrow__InvalidDepositWindow();
    error Escrow__InvalidDeliveryWindow();

    // ENUMS
    enum State {
        AWAITING_DEPOSIT,
        AWAITING_DELIVERY,
        DISPUTED,
        COMPLETE,
        REFUNDED
    }

    // STATE VARIABLES
    address public immutable i_buyer;
    address public immutable i_seller;
    address public immutable i_arbiter;
    address public immutable i_owner;

    uint256 public immutable i_expectedAmount;
    uint256 public immutable i_protocolFeeBps;
    uint256 public immutable i_depositDeadline;
    uint256 public immutable i_deliveryWindow;
    uint256 public s_deliveryDeadline;

    State public s_state;

    mapping(address => uint256) public s_pendingWithdrawals;

    // EVENTS
    event Deposited(address indexed buyer, uint256 amount);
    event DeliveryConfirmed(address indexed seller, uint256 amount);
    event DisputeOpened(address indexed openedBy);
    event DisputeResolved(bool releaseToSeller);
    event Refunded(address indexed buyer, uint256 amount);
    event Withdrawn(address indexed recipient, uint256 amount);

    constructor(
        address _buyer,
        address _seller,
        address _arbiter,
        address _owner,
        uint256 _expectedAmount,
        uint256 _protocolFeeBps,
        uint256 _depositWindow,
        uint256 _deliveryWindow
    ) {
        if (_buyer == address(0)) revert Escrow__InvalidAddress();
        if (_seller == address(0)) revert Escrow__InvalidAddress();
        if (_arbiter == address(0)) revert Escrow__InvalidAddress();
        if (_owner == address(0)) revert Escrow__InvalidAddress();
        if (_buyer == _seller) revert Escrow__SameSellerAndBuyer();
        if (_buyer == _arbiter) revert Escrow__SameBuyerAndArbiter();
        if (_seller == _arbiter) revert Escrow__SameSellerAndArbiter();
        if (_expectedAmount == 0) revert Escrow__InvalidExpectedAmount();
        if (_protocolFeeBps > 500) revert Escrow__InvalidProtocolFee();
        if (_depositWindow == 0) revert Escrow__InvalidDepositWindow();
        if (_deliveryWindow == 0) revert Escrow__InvalidDeliveryWindow();

        i_buyer = _buyer;
        i_seller = _seller;
        i_arbiter = _arbiter;
        i_owner = _owner;
        i_expectedAmount = _expectedAmount;
        i_protocolFeeBps = _protocolFeeBps;
        i_depositDeadline = block.timestamp + _depositWindow;
        i_deliveryWindow = _deliveryWindow;
        s_state = State.AWAITING_DEPOSIT;
    }
}
