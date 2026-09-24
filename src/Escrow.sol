// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/// @title Escrow
/// @author mahz24
/// @notice Single-trade ETH escrow between a buyer and a seller, with an arbiter for disputes
///         and permissionless timeouts that guarantee funds can never be locked forever.
/// @dev Lifecycle: AWAITING_DEPOSIT -> AWAITING_DELIVERY -> (DISPUTED) -> COMPLETE | REFUNDED.
///      Payouts use the pull-payment pattern: state transitions only credit balances in
///      `s_pendingWithdrawals`; ETH leaves the contract exclusively through `withdraw()`.
///      See DESIGN.md for the full transition table and invariants.
contract Escrow {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error Escrow__InvalidAddress();
    error Escrow__SameSellerAndBuyer();
    error Escrow__SameBuyerAndArbiter();
    error Escrow__SameSellerAndArbiter();
    error Escrow__InvalidExpectedAmount();
    error Escrow__InvalidProtocolFee();
    error Escrow__InvalidDepositWindow();
    error Escrow__InvalidDeliveryWindow();
    error Escrow__InvalidDisputeWindow();
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
    error Escrow__DeliveryWindowExpired();
    error Escrow__DisputeWindowNotExpired();
    error Escrow__DisputeWindowExpired();

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/
    enum State {
        AWAITING_DEPOSIT, // Deployed, buyer has not deposited yet
        AWAITING_DELIVERY, // ETH in custody, waiting for delivery confirmation
        DISPUTED, // Dispute opened, arbiter must resolve before the dispute deadline
        COMPLETE, // Seller (and owner fee) credited
        REFUNDED // Buyer credited with the full amount
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Hard cap on the protocol fee: 500 bps = 5%.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 500;
    uint256 private constant BPS_DIVISOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    address public immutable i_buyer;
    address public immutable i_seller;
    address public immutable i_arbiter;
    address public immutable i_owner;

    uint256 public immutable i_expectedAmount;
    uint256 public immutable i_protocolFeeBps;
    uint256 public immutable i_depositDeadline;
    uint256 public immutable i_deliveryWindow;
    uint256 public immutable i_disputeWindow;

    uint256 public s_deliveryDeadline;
    uint256 public s_disputeDeadline;

    State public s_state;

    mapping(address => uint256) public s_pendingWithdrawals;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event Deposited(address indexed buyer, uint256 amount, uint256 deliveryDeadline);
    event DeliveryConfirmed(address indexed seller, uint256 amount);
    event ProtocolFeeCharged(address indexed owner, uint256 fee);
    event DisputeOpened(address indexed openedBy, uint256 disputeDeadline);
    event DisputeResolved(address indexed recipient, bool releaseToSeller, uint256 amount);
    event Refunded(address indexed buyer, uint256 amount);
    event Withdrawn(address indexed recipient, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
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

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /// @param _buyer Address that deposits ETH and confirms delivery.
    /// @param _seller Address that receives the funds (minus fee) on success.
    /// @param _arbiter Trusted address that resolves disputes.
    /// @param _owner Address that receives the protocol fee.
    /// @param _expectedAmount Exact amount of wei the buyer must deposit.
    /// @param _protocolFeeBps Fee in basis points charged on the seller payout (max 500).
    /// @param _depositWindow Seconds (from deployment) the buyer has to deposit.
    /// @param _deliveryWindow Seconds (from deposit) before anyone can trigger a refund.
    /// @param _disputeWindow Seconds (from dispute opening) the arbiter has to resolve.
    constructor(
        address _buyer,
        address _seller,
        address _arbiter,
        address _owner,
        uint256 _expectedAmount,
        uint256 _protocolFeeBps,
        uint256 _depositWindow,
        uint256 _deliveryWindow,
        uint256 _disputeWindow
    ) {
        if (_buyer == address(0)) revert Escrow__InvalidAddress();
        if (_seller == address(0)) revert Escrow__InvalidAddress();
        if (_arbiter == address(0)) revert Escrow__InvalidAddress();
        if (_owner == address(0)) revert Escrow__InvalidAddress();
        if (_buyer == _seller) revert Escrow__SameSellerAndBuyer();
        if (_buyer == _arbiter) revert Escrow__SameBuyerAndArbiter();
        if (_seller == _arbiter) revert Escrow__SameSellerAndArbiter();
        if (_expectedAmount == 0) revert Escrow__InvalidExpectedAmount();
        if (_protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert Escrow__InvalidProtocolFee();
        if (_depositWindow == 0) revert Escrow__InvalidDepositWindow();
        if (_deliveryWindow == 0) revert Escrow__InvalidDeliveryWindow();
        if (_disputeWindow == 0) revert Escrow__InvalidDisputeWindow();

        i_buyer = _buyer;
        i_seller = _seller;
        i_arbiter = _arbiter;
        i_owner = _owner;
        i_expectedAmount = _expectedAmount;
        i_protocolFeeBps = _protocolFeeBps;
        i_depositDeadline = block.timestamp + _depositWindow;
        i_deliveryWindow = _deliveryWindow;
        i_disputeWindow = _disputeWindow;
        s_state = State.AWAITING_DEPOSIT;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Buyer locks exactly `i_expectedAmount` wei and starts the delivery window.
    function deposit() external payable onlyBuyer inState(State.AWAITING_DEPOSIT) {
        // Validator timestamp drift (~seconds) is negligible against hour/day-scale windows.
        if (block.timestamp > i_depositDeadline) revert Escrow__DepositWindowExpired();
        if (msg.value != i_expectedAmount) revert Escrow__WrongPaymentAmount(msg.value, i_expectedAmount);

        s_deliveryDeadline = block.timestamp + i_deliveryWindow;
        s_state = State.AWAITING_DELIVERY;

        emit Deposited(msg.sender, msg.value, s_deliveryDeadline);
    }

    /// @notice Buyer confirms delivery; seller and owner are credited. Final — no dispute afterwards.
    function confirmDelivery() external onlyBuyer inState(State.AWAITING_DELIVERY) {
        s_state = State.COMPLETE;
        uint256 sellerAmount = _creditSeller();

        emit DeliveryConfirmed(i_seller, sellerAmount);
    }

    /// @notice Buyer or seller escalates to the arbiter. Only possible before the delivery deadline,
    ///         so a seller cannot front-run a buyer's `refundOnTimeout()` to freeze the funds.
    function openDispute() external onlySellerOrBuyer inState(State.AWAITING_DELIVERY) {
        if (block.timestamp > s_deliveryDeadline) revert Escrow__DeliveryWindowExpired();

        s_disputeDeadline = block.timestamp + i_disputeWindow;
        s_state = State.DISPUTED;

        emit DisputeOpened(msg.sender, s_disputeDeadline);
    }

    /// @notice Arbiter decides the dispute before the dispute deadline.
    /// @param releaseToSeller true credits the seller (minus fee), false refunds the buyer in full.
    function resolveDispute(bool releaseToSeller) external onlyArbiter inState(State.DISPUTED) {
        if (block.timestamp > s_disputeDeadline) revert Escrow__DisputeWindowExpired();

        if (releaseToSeller) {
            s_state = State.COMPLETE;
            uint256 sellerAmount = _creditSeller();
            emit DisputeResolved(i_seller, true, sellerAmount);
        } else {
            s_state = State.REFUNDED;
            s_pendingWithdrawals[i_buyer] += i_expectedAmount;
            emit DisputeResolved(i_buyer, false, i_expectedAmount);
        }
    }

    /// @notice Anyone can refund the buyer once the delivery deadline has passed without
    ///         confirmation or dispute. Guarantees liveness if the buyer loses their keys.
    function refundOnTimeout() external inState(State.AWAITING_DELIVERY) {
        if (block.timestamp <= s_deliveryDeadline) revert Escrow__DeliveryWindowNotExpired();
        _refundBuyer();
    }

    /// @notice Anyone can refund the buyer if the arbiter failed to act before the dispute deadline.
    ///         Guarantees liveness against an unresponsive arbiter.
    function refundOnDisputeTimeout() external inState(State.DISPUTED) {
        if (block.timestamp <= s_disputeDeadline) revert Escrow__DisputeWindowNotExpired();
        _refundBuyer();
    }

    /// @notice Pulls every wei credited to `msg.sender`. Only available once the escrow is finalized.
    function withdraw() external {
        // Checks
        if (s_state != State.COMPLETE && s_state != State.REFUNDED) revert Escrow__EscrowNotFinalized();
        uint256 amount = s_pendingWithdrawals[msg.sender];
        if (amount == 0) revert Escrow__NothingToWithdraw();

        // Effects
        s_pendingWithdrawals[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);

        // Interactions
        (bool success,) = msg.sender.call{ value: amount }("");
        if (!success) revert Escrow__WithdrawalFailed();
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Protocol fee charged if the seller gets paid.
    function getProtocolFee() public view returns (uint256) {
        return (i_expectedAmount * i_protocolFeeBps) / BPS_DIVISOR;
    }

    /// @notice Amount the seller receives if the escrow completes.
    function getSellerPayout() external view returns (uint256) {
        return i_expectedAmount - getProtocolFee();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _creditSeller() internal returns (uint256 sellerAmount) {
        uint256 fee = getProtocolFee();
        sellerAmount = i_expectedAmount - fee;

        s_pendingWithdrawals[i_seller] += sellerAmount;
        s_pendingWithdrawals[i_owner] += fee;

        emit ProtocolFeeCharged(i_owner, fee);
    }

    function _refundBuyer() internal {
        s_state = State.REFUNDED;
        s_pendingWithdrawals[i_buyer] += i_expectedAmount;

        emit Refunded(i_buyer, i_expectedAmount);
    }
}
