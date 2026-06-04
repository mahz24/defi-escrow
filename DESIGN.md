# Escrow — Diseño

  ## Roles
  - `buyer`: Deposit ETH in the contract.
  - `seller`: Delivers a service or product
  - `arbiter`: Resolves disputes between buyer and seller
  - `owner`: Receives the protocol fee on successful deliveries

  ## State
  enum State {
    AWAITING_DEPOSIT,  // Contract created, buyer has not deposited yet
    AWAITING_DELIVERY, // ETH in custody, waiting for delivery confirmation
    DISPUTED,          // Dispute opened, arbiter must resolve
    COMPLETE,          // Delivery confirmed, funds released to seller
    REFUNDED           // Funds returned to buyer
  }

  ## State Variables (storage)
  address private buyer             // deposits ETH and confirms delivery
  address private seller            // receives funds on successful delivery
  address private arbiter           // resolves disputes between buyer and seller
  address private owner             // receives the protocol fee

  uint256 private amount            // deposited ETH (excluding fee)
  uint256 private protocolFeeBps    // fee in basis points (e.g. 100 = 1%)
  uint256 private depositDeadline   // timestamp deadline for buyer to deposit
  uint256 private deliveryDeadline  // timestamp deadline to confirm delivery
                                    // (starts counting from deposit)

  State   private state             // current contract state

  mapping(address => uint256) private pendingWithdrawals
// tracks credited amounts for Pull pattern withdrawals

  ## Transition Table

  | Function               | Who can call   | Origin state      | Destination state     | Effects                                                                 | Reverts if...                                                                 |
  |------------------------|----------------|-------------------|-----------------------|-------------------------------------------------------------------------|-------------------------------------------------------------------------------|
  | `deposit()`            | buyer          | AWAITING_DEPOSIT  | AWAITING_DELIVERY     | Stores msg.value as amount, starts deliveryDeadline. Emits Deposited(buyer, amount) | msg.sender != buyer / state != AWAITING_DEPOSIT / msg.value == 0 / depositDeadline passed |
  | `confirmDelivery()` | buyer | AWAITING_DELIVERY | COMPLETE | Credits pendingWithdrawals[seller] += amount - fee and pendingWithdrawals[owner] += fee. No ETH transferred yet. Emits DeliveryConfirmed(seller, amount) | msg.sender != buyer / state != AWAITING_DELIVERY |
  | `openDispute()`        | buyer or seller| AWAITING_DELIVERY | DISPUTED              | State change only. Emits DisputeOpened(msg.sender)                      | msg.sender != buyer && msg.sender != seller / state != AWAITING_DELIVERY     |
  | `resolveDispute(bool)` | arbiter        | DISPUTED          | COMPLETE or REFUNDED  | Credits pendingWithdrawals[seller] += amount - fee (if true) or pendingWithdrawals[buyer] += amount (if false). Emits DisputeResolved(releaseToSeller) | msg.sender != arbiter / state != DISPUTED                                    |
  | `refundOnTimeout()`    | anyone         | AWAITING_DELIVERY | REFUNDED              | Credits pendingWithdrawals[buyer] += amount. Emits Refunded(buyer, amount)      |  state != AWAITING_DELIVERY / block.timestamp < deliveryDeadline |
  | `withdraw()` | seller, buyer, or owner | COMPLETE or REFUNDED | — | Transfers pendingWithdrawals[msg.sender]. Sets pendingWithdrawals[msg.sender] = 0. Emits Withdrawn(recipient, amount) | pendingWithdrawals[msg.sender] == 0 |

  > Note: `refundOnTimeout()` is intentionally callable by anyone. The outcome
  > is always predetermined — funds always return to buyer. This prevents funds
  > from being permanently locked if the buyer loses access to their wallet.
  > The caller only pays gas; they receive nothing.


  ## Invariants

  1. While state == AWAITING_DELIVERY or DISPUTED:
    amount > 0 and no pendingWithdrawals exist
    (the deposit is fully locked, no withdrawals yet credited)

  2. buyer, seller, and arbiter are always distinct addresses
    (enforced in constructor)

  3. ETH can only be deposited once
    (deposit() is only valid from AWAITING_DEPOSIT state)

  4. Once state == COMPLETE or REFUNDED, amount == 0
    (no funds remain tracked internally)

  5. protocolFeeBps <= 500 at all times
    (enforced in constructor, cap protects against abusive deployments)


  ## Forbidden Cases (must revert)

  - deposit() called more than once
  - deposit() with msg.value == 0
  - deposit() after depositDeadline has passed
  - confirmDelivery() called by seller or arbiter
  - confirmDelivery() when state == DISPUTED
  - openDispute() called by arbiter
  - openDispute() when state == AWAITING_DEPOSIT, COMPLETE, or REFUNDED
  - resolveDispute() called by buyer or seller
  - resolveDispute() when state != DISPUTED
  - refundOnTimeout() before deliveryDeadline has passed
  - refundOnTimeout() when state == DISPUTED (arbiter must resolve instead)
  - Constructor with buyer == seller, buyer == arbiter, or seller == arbiter
  - Constructor with _buyer == address(0)
  - Constructor with _seller == address(0)
  - Constructor with _arbiter == address(0)
  - Constructor with _owner == address(0)
  - Constructor with _protocolFeeBps > 500 (5% max cap)
  - Constructor with _depositWindow == 0
  - Constructor with _deliveryWindow == 0

  > Note: once buyer calls confirmDelivery(), the dispute window closes.
  > Buyer assumes full risk at confirmation — protection must be requested before confirming.

  > Note: protocol fee is only charged when seller receives funds.
  > Refunds (timeout or dispute) always return the full amount to buyer.


  ## Constructor Parameters

  constructor(
      address _buyer,           // address that will deposit and confirm delivery
      address _seller,          // address that will receive funds
      address _arbiter,         // address that will resolve disputes
      address _owner,           // address that receives the protocol fee
      uint256 _protocolFeeBps,  // fee percentage in basis points (100 = 1%)
      uint256 _depositWindow,   // seconds buyer has to deposit after deployment
      uint256 _deliveryWindow   // seconds buyer has to confirm delivery after deposit
  )

  // Validations:
  // All addresses must be non-zero — a zero address would make the contract
  // permanently unusable since no one can satisfy role-based checks.

  ### Why each param:
  - _buyer / _seller / _arbiter → define the three roles, must be distinct
  - _owner → decouples fee recipient from deployer, more flexible
  - _depositWindow → prevents the contract from waiting forever for a deposit
  - _deliveryWindow → starts on deposit, gives buyer a fair window to confirm
  - _protocolFeeBps → capped at 500 (5% max). Recommended production value is 100 (1%). Cap exists as a safety bound, not as the intended operating fee.


  ## Payment Pattern

  This contract uses the **Pull Payment** pattern instead of Push.

  - `confirmDelivery()` and `resolveDispute()` only credit a
    `mapping(address => uint256) pendingWithdrawals` — no ETH moves.
  - Funds are transferred only when the recipient calls `withdraw()`.

  **Why Pull over Push:**
  With Push, if the seller is a malicious contract whose `receive()`
  reverts, `confirmDelivery()` fails entirely — the escrow never reaches
  COMPLETE and funds are permanently trapped. With Pull, escrow
  finalization is separated from ETH transfer. If `withdraw()` fails,
  it only affects the caller — the escrow state is already COMPLETE.

  **New function needed:**
  `withdraw()` — callable by seller, buyer or owner after state == COMPLETE
  or REFUNDED. Transfers pendingWithdrawals[msg.sender] to caller.


  ## Security Notes

  ### 1. ETH Transfer Method
  `transfer` and `send` have a fixed gas stipend of 2,300 gas which is
  not enough for contracts with non-trivial `receive()` functions,
  causing reverts and trapped funds. This contract uses `call` instead,
  which forwards all available gas. The return bool is always checked:

  (bool ok,) = recipient.call{value: amount}("");
  require(ok, "ETH transfer failed");

  ### 2. Reentrancy
  Reentrancy occurs when an external contract re-enters a function
  before its execution completes, potentially draining funds.
  This contract follows the CEI pattern (Checks-Effects-Interactions)
  on every fund-moving function — state is always updated before
  any external call. The Pull pattern provides an additional layer
  of protection since no ETH moves in `confirmDelivery()` or
  `resolveDispute()`.

  ### 3. Balance Pitfall (strict equality)
  `address(this).balance` can be manipulated by anyone via
  `selfdestruct` — ETH can be forced into the contract bypassing
  `receive()`. This contract never uses `address(this).balance`
  for internal logic. Instead, the `amount` state variable tracks the deposited ETH internally.
  Only `deposit()` can modify it, making it immune to forced ETH injection.

  ### 4. Known Limitations
  - Arbiter is a single trusted address — no multi-sig support.
  - Once buyer calls `confirmDelivery()`, no dispute can be opened.
    Buyer assumes full risk at confirmation.
  - Protocol fee is only charged when seller receives funds.
    Refunds always return the full deposited amount to buyer.


  ## Events

  event Deposited(address indexed buyer, uint256 amount);
  event DeliveryConfirmed(address indexed seller, uint256 amount);
  event DisputeOpened(address indexed openedBy);
  event DisputeResolved(bool releaseToSeller);
  event Refunded(address indexed buyer, uint256 amount);
  event Withdrawn(address indexed recipient, uint256 amount);