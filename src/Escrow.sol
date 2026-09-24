// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Hard cap on the protocol fee (500 bps = 5%), shared with EscrowFactory.
uint256 constant MAX_FEE_BPS = 500;

/// @title Escrow
/// @author mahz24
/// @notice Single-trade escrow for native ETH or any standard ERC-20 between a buyer and a seller,
///         with an arbiter for disputes and permissionless timeouts that guarantee funds can never
///         be locked forever.
/// @dev Deployed as an EIP-1167 minimal-proxy clone by `EscrowFactory` and configured once through
///      `initialize()`. The implementation contract itself can never be initialized.
///      Lifecycle: AWAITING_DEPOSIT -> AWAITING_DELIVERY -> (DISPUTED) -> COMPLETE | REFUNDED.
///      Payouts use the pull-payment pattern: state transitions only credit `s_pendingWithdrawals`;
///      assets leave the contract exclusively through `withdraw()` / `withdrawTo()`.
///      See DESIGN.md for the full transition table and invariants.
contract Escrow is Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error Escrow__InvalidAddress();
    error Escrow__InvalidToken();
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
    error Escrow__UnexpectedEth();
    error Escrow__FeeOnTransferNotSupported(uint256 received, uint256 expected);
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
        AWAITING_DEPOSIT, // Created, buyer has not deposited yet
        AWAITING_DELIVERY, // Funds in custody, waiting for delivery confirmation
        DISPUTED, // Dispute opened, arbiter must resolve before the dispute deadline
        COMPLETE, // Seller (and protocol fee) credited
        REFUNDED // Buyer credited with the full amount
    }

    /// @notice Trade terms chosen by whoever creates the escrow.
    /// @param buyer Address that deposits and confirms delivery.
    /// @param seller Address that receives the payout (minus fee) on success.
    /// @param arbiter Trusted address that resolves disputes.
    /// @param token ERC-20 used for payment, or `NATIVE_TOKEN` (address(0)) for ETH.
    /// @param amount Exact amount (wei / token base units) the buyer must deposit.
    /// @param depositWindow Seconds (from creation) the buyer has to deposit. Windows must fit in uint32.
    /// @param deliveryWindow Seconds (from deposit) before anyone can trigger a refund.
    /// @param disputeWindow Seconds (from dispute opening) the arbiter has to resolve.
    struct EscrowParams {
        address buyer;
        address seller;
        address arbiter;
        address token;
        uint256 amount;
        uint256 depositWindow;
        uint256 deliveryWindow;
        uint256 disputeWindow;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Sentinel for "pay in native ETH".
    address public constant NATIVE_TOKEN = address(0);
    /// @notice Hard cap on the protocol fee: 500 bps = 5%.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = MAX_FEE_BPS;
    uint256 private constant BPS_DIVISOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    // Clones cannot use immutables (they live in the implementation's bytecode), so trade terms are storage
    // variables written exactly once in `initialize()`. They are packed into 7 slots instead of 12:
    // deadlines fit in uint64 (year 584 billion), windows in uint32 (136 years), the capped fee in uint16.
    address public s_buyer;
    address public s_seller;
    address public s_arbiter;
    address public s_feeRecipient;

    // Slot 4 (31 bytes): token + state + fee + deposit deadline
    address public s_token;
    State public s_state;
    uint16 public s_protocolFeeBps;
    uint64 public s_depositDeadline;

    // Slot 5 (24 bytes): windows + deadlines
    uint32 public s_deliveryWindow;
    uint32 public s_disputeWindow;
    uint64 public s_deliveryDeadline;
    uint64 public s_disputeDeadline;

    uint256 public s_amount;

    mapping(address => uint256) public s_pendingWithdrawals;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event EscrowInitialized(
        address indexed buyer, address indexed seller, address indexed arbiter, address token, uint256 amount
    );
    event Deposited(address indexed buyer, uint256 amount, uint256 deliveryDeadline);
    event DeliveryConfirmed(address indexed seller, uint256 amount);
    event ProtocolFeeCharged(address indexed feeRecipient, uint256 fee);
    event DisputeOpened(address indexed openedBy, uint256 disputeDeadline);
    event DisputeResolved(address indexed recipient, bool releaseToSeller, uint256 amount);
    event Refunded(address indexed buyer, uint256 amount);
    event Withdrawn(address indexed account, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier onlyBuyer() {
        if (msg.sender != s_buyer) revert Escrow__NotBuyer();
        _;
    }

    modifier onlyArbiter() {
        if (msg.sender != s_arbiter) revert Escrow__NotArbiter();
        _;
    }

    modifier onlySellerOrBuyer() {
        if (msg.sender != s_seller && msg.sender != s_buyer) revert Escrow__NotSellerOrBuyer();
        _;
    }

    modifier inState(State expectedState) {
        if (s_state != expectedState) revert Escrow__WrongState(expectedState, s_state);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                         CONSTRUCTOR / INITIALIZER
    //////////////////////////////////////////////////////////////*/
    /// @dev Locks the implementation so only clones can be initialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Configures a freshly cloned escrow. Callable exactly once.
    /// @param p Trade terms.
    /// @param feeRecipient Address that receives the protocol fee (set by the factory).
    /// @param protocolFeeBps Fee in basis points charged on the seller payout (max 500).
    function initialize(EscrowParams calldata p, address feeRecipient, uint256 protocolFeeBps) external initializer {
        if (p.buyer == address(0) || p.seller == address(0) || p.arbiter == address(0)) {
            revert Escrow__InvalidAddress();
        }
        if (feeRecipient == address(0)) revert Escrow__InvalidAddress();
        if (p.buyer == p.seller) revert Escrow__SameSellerAndBuyer();
        if (p.buyer == p.arbiter) revert Escrow__SameBuyerAndArbiter();
        if (p.seller == p.arbiter) revert Escrow__SameSellerAndArbiter();
        if (p.token != NATIVE_TOKEN && p.token.code.length == 0) revert Escrow__InvalidToken();
        if (p.amount == 0) revert Escrow__InvalidExpectedAmount();
        if (protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert Escrow__InvalidProtocolFee();
        if (p.depositWindow == 0 || p.depositWindow > type(uint32).max) revert Escrow__InvalidDepositWindow();
        if (p.deliveryWindow == 0 || p.deliveryWindow > type(uint32).max) revert Escrow__InvalidDeliveryWindow();
        if (p.disputeWindow == 0 || p.disputeWindow > type(uint32).max) revert Escrow__InvalidDisputeWindow();

        s_buyer = p.buyer;
        s_seller = p.seller;
        s_arbiter = p.arbiter;
        s_feeRecipient = feeRecipient;
        s_token = p.token;
        s_amount = p.amount;
        // Safe casts: fee <= 500, windows <= type(uint32).max (checked above), timestamps fit in uint64.
        // forge-lint: disable-next-line(unsafe-typecast)
        s_protocolFeeBps = uint16(protocolFeeBps);
        // forge-lint: disable-next-line(unsafe-typecast)
        s_depositDeadline = uint64(block.timestamp + p.depositWindow);
        // forge-lint: disable-next-line(unsafe-typecast)
        s_deliveryWindow = uint32(p.deliveryWindow);
        // forge-lint: disable-next-line(unsafe-typecast)
        s_disputeWindow = uint32(p.disputeWindow);
        s_state = State.AWAITING_DEPOSIT;

        emit EscrowInitialized(p.buyer, p.seller, p.arbiter, p.token, p.amount);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Buyer locks exactly `s_amount` and starts the delivery window.
    /// @dev ETH escrows require `msg.value == s_amount`. ERC-20 escrows require `msg.value == 0` and a
    ///      prior `approve(escrow, s_amount)`. Tokens that deliver less than requested (fee-on-transfer)
    ///      are rejected so the escrow can never owe more than it holds.
    function deposit() external payable nonReentrant onlyBuyer inState(State.AWAITING_DEPOSIT) {
        // Validator timestamp drift (~seconds) is negligible against hour/day-scale windows.
        if (block.timestamp > s_depositDeadline) revert Escrow__DepositWindowExpired();

        uint256 amount = s_amount;
        address token = s_token;
        if (token == NATIVE_TOKEN) {
            if (msg.value != amount) revert Escrow__WrongPaymentAmount(msg.value, amount);
        } else if (msg.value != 0) {
            revert Escrow__UnexpectedEth();
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        s_deliveryDeadline = uint64(block.timestamp) + s_deliveryWindow;
        s_state = State.AWAITING_DELIVERY;
        emit Deposited(msg.sender, amount, s_deliveryDeadline);

        if (token != NATIVE_TOKEN) {
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
            if (received != amount) revert Escrow__FeeOnTransferNotSupported(received, amount);
        }
    }

    /// @notice Buyer confirms delivery; seller and fee recipient are credited. Final — no dispute afterwards.
    function confirmDelivery() external onlyBuyer inState(State.AWAITING_DELIVERY) {
        s_state = State.COMPLETE;
        uint256 sellerAmount = _creditSeller();

        emit DeliveryConfirmed(s_seller, sellerAmount);
    }

    /// @notice Buyer or seller escalates to the arbiter. Only possible before the delivery deadline,
    ///         so a seller cannot front-run a buyer's `refundOnTimeout()` to freeze the funds.
    function openDispute() external onlySellerOrBuyer inState(State.AWAITING_DELIVERY) {
        if (block.timestamp > s_deliveryDeadline) revert Escrow__DeliveryWindowExpired();

        // forge-lint: disable-next-line(unsafe-typecast)
        s_disputeDeadline = uint64(block.timestamp) + s_disputeWindow;
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
            emit DisputeResolved(s_seller, true, sellerAmount);
        } else {
            s_state = State.REFUNDED;
            s_pendingWithdrawals[s_buyer] += s_amount;
            emit DisputeResolved(s_buyer, false, s_amount);
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

    /// @notice Pulls everything credited to `msg.sender` to `msg.sender`.
    function withdraw() external nonReentrant {
        _withdraw(msg.sender);
    }

    /// @notice Pulls everything credited to `msg.sender` to another address.
    /// @dev Escape hatch for recipients that cannot receive the asset themselves
    ///      (e.g. a contract without `receive()`, or an address blocklisted by the token).
    function withdrawTo(address to) external nonReentrant {
        if (to == address(0)) revert Escrow__InvalidAddress();
        _withdraw(to);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Protocol fee charged if the seller gets paid.
    function getProtocolFee() public view returns (uint256) {
        return (s_amount * s_protocolFeeBps) / BPS_DIVISOR;
    }

    /// @notice Amount the seller receives if the escrow completes.
    function getSellerPayout() external view returns (uint256) {
        return s_amount - getProtocolFee();
    }

    /// @notice True if the escrow is denominated in native ETH.
    function isNative() external view returns (bool) {
        return s_token == NATIVE_TOKEN;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _withdraw(address to) internal {
        // Checks
        if (s_state != State.COMPLETE && s_state != State.REFUNDED) revert Escrow__EscrowNotFinalized();
        uint256 amount = s_pendingWithdrawals[msg.sender];
        if (amount == 0) revert Escrow__NothingToWithdraw();

        // Effects
        s_pendingWithdrawals[msg.sender] = 0;
        emit Withdrawn(msg.sender, to, amount);

        // Interactions
        address token = s_token;
        if (token == NATIVE_TOKEN) {
            (bool success,) = to.call{ value: amount }("");
            if (!success) revert Escrow__WithdrawalFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _creditSeller() internal returns (uint256 sellerAmount) {
        uint256 fee = getProtocolFee();
        sellerAmount = s_amount - fee;

        s_pendingWithdrawals[s_seller] += sellerAmount;
        s_pendingWithdrawals[s_feeRecipient] += fee;

        emit ProtocolFeeCharged(s_feeRecipient, fee);
    }

    function _refundBuyer() internal {
        s_state = State.REFUNDED;
        s_pendingWithdrawals[s_buyer] += s_amount;

        emit Refunded(s_buyer, s_amount);
    }
}
