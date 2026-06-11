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
    error Escrow__NotBuyer();
    error Escrow__NotArbiter();
    error Escrow__NotSellerOrBuyer();
    error Escrow__WrongState(State expected, State current);
    error Escrow__DepositWindowExpired();
    error Escrow__WrongPaymentAmount(uint256 sent, uint256 expected);
    error Escrow__EscrowNotFinalized();
    error Escrow__NothingToWithdraw();
    error Escrow__WithdrawalFailed();
    error Escrow__DeliveryWindowNotExpired();

    // ENUMS
    enum State {
        AWAITING_DEPOSIT,
        AWAITING_DELIVERY,
        DISPUTED,
        COMPLETE,
        REFUNDED
    }

    // CONSTANTS
    uint256 private constant BPS_DIVISOR = 10_000;

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

    // MODIFIERS
    modifier onlyBuyer() {
        if (msg.sender != i_buyer) revert Escrow__NotBuyer();
        _;
    }

    modifier onlyArbiter() {
        if (msg.sender != i_arbiter) revert Escrow__NotArbiter();
        _;
    }

    modifier onlySellerOrBuyer() {
        if (msg.sender != i_seller && msg.sender != i_buyer) revert Escrow__NotSellerOrBuyer();
        _;
    }

    modifier inState(State expectedState) {
        if (s_state != expectedState) revert Escrow__WrongState(expectedState, s_state);
        _;
    }

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

    function deposit() external payable onlyBuyer inState(State.AWAITING_DEPOSIT) {
        // Checks
        // Acceptable: deadline windows are measured in hours/days,
        // validator timestamp wiggle (~15s) is negligible.
        if (block.timestamp > i_depositDeadline) revert Escrow__DepositWindowExpired();
        if (msg.value != i_expectedAmount) revert Escrow__WrongPaymentAmount(msg.value, i_expectedAmount);

        // Effects
        s_deliveryDeadline = block.timestamp + i_deliveryWindow;
        s_state = State.AWAITING_DELIVERY;

        // Interactions
        emit Deposited(msg.sender, msg.value);
    }

    function confirmDelivery() external onlyBuyer inState(State.AWAITING_DELIVERY) {
        (uint256 sellerAmount,) = _creditSeller();

        // Effects
        s_state = State.COMPLETE;

        // Interactions
        emit DeliveryConfirmed(i_seller, sellerAmount);
    }

    function withdraw() external {
        // Checks
        if (s_state != State.COMPLETE && s_state != State.REFUNDED) revert Escrow__EscrowNotFinalized();
        uint256 amount = s_pendingWithdrawals[msg.sender];
        if (amount == 0) revert Escrow__NothingToWithdraw();

        // Effects
        s_pendingWithdrawals[msg.sender] = 0;

        // Interactions
        (bool success,) = msg.sender.call{ value: amount }("");
        if (!success) revert Escrow__WithdrawalFailed();

        emit Withdrawn(msg.sender, amount);
    }

    function openDispute() external onlySellerOrBuyer inState(State.AWAITING_DELIVERY) {
        s_state = State.DISPUTED;
        emit DisputeOpened(msg.sender);
    }

    function resolveDispute(bool releaseToSeller) external onlyArbiter inState(State.DISPUTED) {
        if (releaseToSeller) {
            _creditSeller();
        } else {
            s_pendingWithdrawals[i_buyer] += i_expectedAmount;
        }

        s_state = releaseToSeller ? State.COMPLETE : State.REFUNDED;
        emit DisputeResolved(releaseToSeller);
    }

    function refundOnTimeout() external inState(State.AWAITING_DELIVERY) {
        if (block.timestamp <= s_deliveryDeadline) revert Escrow__DeliveryWindowNotExpired();

        s_pendingWithdrawals[i_buyer] += i_expectedAmount;
        s_state = State.REFUNDED;

        emit Refunded(i_buyer, i_expectedAmount);
    }

    function _creditSeller() internal returns (uint256, uint256) {
        uint256 fee = (i_expectedAmount * i_protocolFeeBps) / BPS_DIVISOR;

        s_pendingWithdrawals[i_seller] += i_expectedAmount - fee;
        s_pendingWithdrawals[i_owner] += fee;
        return (i_expectedAmount - fee, fee);
    }
}
