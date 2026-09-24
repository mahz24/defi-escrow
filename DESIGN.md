# Escrow — Design

This document is the specification the contract and the test suite are built against.
Every rule below is enforced in [`src/Escrow.sol`](./src/Escrow.sol) and covered by at least one
test (unit, fuzz or invariant).

---

## 1. Roles

| Role      | Responsibility                                                        |
|-----------|-----------------------------------------------------------------------|
| `buyer`   | Deposits the exact escrow amount and confirms delivery.               |
| `seller`  | Delivers the product/service off-chain; receives the payout.          |
| `arbiter` | Trusted third party that resolves disputes within the dispute window. |
| `owner`   | Receives the protocol fee when (and only when) the seller is paid.    |
| anyone    | Can trigger the two timeout refunds (liveness guarantees).            |

`buyer`, `seller` and `arbiter` must be pairwise distinct. `owner` may coincide with the arbiter
(e.g. a platform that both arbitrates and charges the fee).

---

## 2. State machine

```
AWAITING_DEPOSIT ──deposit()──► AWAITING_DELIVERY ──confirmDelivery()──────────► COMPLETE
                                   │        │
                                   │        └──refundOnTimeout() [after delivery deadline]──► REFUNDED
                                   │
                                   └──openDispute() [before delivery deadline]──► DISPUTED
                                                                                   │
                                          resolveDispute(true)  [before deadline] ─┼──► COMPLETE
                                          resolveDispute(false) [before deadline] ─┼──► REFUNDED
                                          refundOnDisputeTimeout() [after deadline]┘──► REFUNDED
```

```solidity
enum State {
    AWAITING_DEPOSIT,  // Deployed, buyer has not deposited yet
    AWAITING_DELIVERY, // ETH in custody, waiting for delivery confirmation
    DISPUTED,          // Dispute opened, arbiter must resolve before the dispute deadline
    COMPLETE,          // Seller (and owner fee) credited
    REFUNDED           // Buyer credited with the full amount
}
```

`COMPLETE` and `REFUNDED` are terminal. The only function available afterwards is `withdraw()`.

---

## 3. Storage

| Variable                | Kind        | Meaning                                                            |
|-------------------------|-------------|--------------------------------------------------------------------|
| `i_buyer`               | immutable   | Buyer address                                                      |
| `i_seller`              | immutable   | Seller address                                                     |
| `i_arbiter`             | immutable   | Arbiter address                                                    |
| `i_owner`               | immutable   | Fee recipient                                                      |
| `i_expectedAmount`      | immutable   | Exact wei the buyer must deposit — source of truth for accounting  |
| `i_protocolFeeBps`      | immutable   | Fee in basis points (100 = 1%), capped at `MAX_PROTOCOL_FEE_BPS`   |
| `i_depositDeadline`     | immutable   | `deploy timestamp + depositWindow`                                 |
| `i_deliveryWindow`      | immutable   | Seconds, counted from the deposit                                  |
| `i_disputeWindow`       | immutable   | Seconds, counted from the moment the dispute is opened             |
| `s_deliveryDeadline`    | storage     | Set in `deposit()`                                                 |
| `s_disputeDeadline`     | storage     | Set in `openDispute()`                                             |
| `s_state`               | storage     | Current `State`                                                    |
| `s_pendingWithdrawals`  | storage     | `address => wei` credited and not yet withdrawn (pull payments)    |
| `MAX_PROTOCOL_FEE_BPS`  | constant    | `500` (5%)                                                         |

All variables are `public`, so every value can be read on-chain and in tests without extra getters.
Two convenience views are exposed: `getProtocolFee()` and `getSellerPayout()`.

The `i_` / `s_` prefixes mark immutables and storage variables. That makes the gas cost of each
read obvious when reviewing the code.

---

## 4. Transition table

| Function                   | Caller            | From              | To                  | Time condition                          | Effects / events |
|----------------------------|-------------------|-------------------|---------------------|-----------------------------------------|------------------|
| `deposit()`                | buyer             | AWAITING_DEPOSIT  | AWAITING_DELIVERY   | `now <= i_depositDeadline`              | `s_deliveryDeadline = now + i_deliveryWindow`. Emits `Deposited(buyer, amount, deliveryDeadline)` |
| `confirmDelivery()`        | buyer             | AWAITING_DELIVERY | COMPLETE            | —                                       | Credits seller `amount - fee`, owner `fee`. Emits `ProtocolFeeCharged(owner, fee)`, `DeliveryConfirmed(seller, amount - fee)` |
| `openDispute()`            | buyer or seller   | AWAITING_DELIVERY | DISPUTED            | `now <= s_deliveryDeadline`             | `s_disputeDeadline = now + i_disputeWindow`. Emits `DisputeOpened(caller, disputeDeadline)` |
| `resolveDispute(true)`     | arbiter           | DISPUTED          | COMPLETE            | `now <= s_disputeDeadline`              | Credits seller `amount - fee`, owner `fee`. Emits `ProtocolFeeCharged`, `DisputeResolved(seller, true, amount - fee)` |
| `resolveDispute(false)`    | arbiter           | DISPUTED          | REFUNDED            | `now <= s_disputeDeadline`              | Credits buyer `amount`. Emits `DisputeResolved(buyer, false, amount)` |
| `refundOnTimeout()`        | anyone            | AWAITING_DELIVERY | REFUNDED            | `now > s_deliveryDeadline`              | Credits buyer `amount`. Emits `Refunded(buyer, amount)` |
| `refundOnDisputeTimeout()` | anyone            | DISPUTED          | REFUNDED            | `now > s_disputeDeadline`               | Credits buyer `amount`. Emits `Refunded(buyer, amount)` |
| `withdraw()`               | any credited addr | COMPLETE/REFUNDED | —                   | —                                       | Zeroes the caller's credit, emits `Withdrawn(caller, credit)`, then sends ETH |

Deadline checks are inclusive for the action that has to happen *before* the deadline
(`deposit`, `openDispute`, `resolveDispute`) and strict for the timeouts (`> deadline`). So at
every second exactly one side of each deadline is valid.

---

## 5. Invariants

Each invariant is checked by the stateful fuzzing suite
([`test/invariant/EscrowInvariantTest.t.sol`](./test/invariant/EscrowInvariantTest.t.sol)) after every
random call. A campaign runs 128,000+ calls.

| # | Invariant | Test |
|---|-----------|------|
| 1 | While the escrow is not finalized, no address has credited funds. | `invariant_noCreditsBeforeFinalization` |
| 2 | ETH held + ETH withdrawn == ETH deposited. No wei is ever created or lost. | `invariant_fundsAreConserved` |
| 3 | The contract balance always equals what it owes (solvency). | `invariant_balanceEqualsOwed` |
| 4 | Once finalized, credited + withdrawn == `i_expectedAmount`. | `invariant_finalizedEscrowAccountsForFullAmount` |
| 5 | Outcomes are exclusive: `COMPLETE` pays only seller + owner (exact split). `REFUNDED` pays only the buyer, in full. | `invariant_outcomesAreExclusive` |
| 6 | The state machine only moves forward, and a terminal state never changes. | `invariant_stateMachineIsMonotonic` |
| 7 | Deadlines match the state that set them. | `invariant_deadlinesAreConsistent` |
| 8 | `i_protocolFeeBps <= 500`. | `invariant_feeWithinCap` |
| 9 | `buyer`, `seller` and `arbiter` are pairwise distinct and non-zero. | constructor unit tests |

---

## 6. Must-revert cases

**Constructor**
- Any role is `address(0)`.
- `buyer == seller`, `buyer == arbiter` or `seller == arbiter`.
- `_expectedAmount == 0`.
- `_protocolFeeBps > 500`.
- `_depositWindow`, `_deliveryWindow` or `_disputeWindow` is `0`.

**Runtime**
- `deposit()`: not the buyer, not in `AWAITING_DEPOSIT` (no double deposit), after the deposit
  deadline, or `msg.value != i_expectedAmount`.
- `confirmDelivery()`: not the buyer, or not in `AWAITING_DELIVERY` (e.g. while disputed).
- `openDispute()`: not buyer/seller (the arbiter can't open one), not in `AWAITING_DELIVERY`, or after
  the delivery deadline.
- `resolveDispute()`: not the arbiter, not in `DISPUTED`, or after the dispute deadline.
- `refundOnTimeout()`: not in `AWAITING_DELIVERY` (e.g. while disputed), or at/before the delivery deadline.
- `refundOnDisputeTimeout()`: not in `DISPUTED`, or at/before the dispute deadline.
- `withdraw()`: escrow not finalized, or nothing credited to the caller.
- Plain ETH transfers: the contract has no `receive`/`fallback`, so they revert.

---

## 7. Constructor

```solidity
constructor(
    address _buyer,
    address _seller,
    address _arbiter,
    address _owner,
    uint256 _expectedAmount,  // exact wei the buyer must deposit
    uint256 _protocolFeeBps,  // 100 = 1%, max 500
    uint256 _depositWindow,   // seconds from deployment to deposit
    uint256 _deliveryWindow,  // seconds from deposit until anyone can refund
    uint256 _disputeWindow    // seconds from dispute opening for the arbiter to act
)
```

- **Non-zero roles.** A zero address would make the escrow unusable, because no one could satisfy the role checks.
- **`_owner` is separate from the deployer.** The fee recipient can be a treasury or multisig.
- **`_depositWindow`.** The escrow can't wait forever for a deposit.
- **`_deliveryWindow`.** Starts at deposit, so the seller always gets the full window.
- **`_disputeWindow`.** Bounds how long an arbiter can hold funds hostage by doing nothing.
- **`_protocolFeeBps`.** The 5% cap is a safety bound against abusive deployments. The intended value is 1%.
- **`_expectedAmount`.** Fixed at deployment, so there is no ambiguity about the price.

---

## 8. Payment pattern: pull over push

`confirmDelivery()`, `resolveDispute()` and the timeout functions only credit
`s_pendingWithdrawals`. ETH leaves the contract only in `withdraw()`.

With push payments, a seller contract whose `receive()` reverts would make `confirmDelivery()`
revert forever, and the funds would be trapped. With pull payments, finalization and ETH transfer
are decoupled. A failing `withdraw()` only affects the caller, while the escrow state and every
other party's credit are unaffected (`testWithdraw_revertsIfCallFails`).

---

## 9. Security notes

### 9.1 ETH transfer method
`transfer`/`send` forward only 2,300 gas, which breaks smart-contract wallets (Safe, ERC-4337
accounts). `withdraw()` uses `call{value: amount}("")` and reverts with
`Escrow__WithdrawalFailed()` if the call fails.

### 9.2 Reentrancy
`withdraw()` follows Checks-Effects-Interactions strictly: it zeroes the credit and emits the event
before the external call. Re-entering finds a zero balance and reverts with `Escrow__NothingToWithdraw`.
This is proven by `testWithdraw_reentrancyCannotDoubleSpend`, which uses the malicious
`ReentrantReceiver` mock. No other function performs external calls, so no `nonReentrant` guard is needed.

### 9.3 Forced ETH
`selfdestruct` or coinbase rewards can push ETH into the contract without calling any function.
The contract never reads `address(this).balance`. `i_expectedAmount` (immutable) is the only
source of truth, so forced ETH cannot break accounting. It simply stays in the contract.

### 9.4 Timestamp dependence
Validators can skew `block.timestamp` by a few seconds. That is negligible against windows measured
in days. Boundary behaviour at `deadline` and `deadline + 1` is covered by unit and fuzz tests.

### 9.5 Liveness: funds can never be locked forever

| Stuck party           | Escape hatch                                                    |
|-----------------------|-----------------------------------------------------------------|
| Buyer never deposits  | Nothing is at risk. The escrow expires after `i_depositDeadline`. |
| Buyer disappears      | `refundOnTimeout()` after the delivery deadline, callable by anyone. |
| Arbiter disappears    | `refundOnDisputeTimeout()` after the dispute deadline, callable by anyone. |
| Recipient can't receive ETH | Only their own credit is stuck. Everyone else can still withdraw. |

### 9.6 Front-running the timeout
In v2, a seller could watch the mempool and call `openDispute()` right after the delivery
deadline, blocking the buyer's `refundOnTimeout()`. v3 closes this: `openDispute()` reverts once
the delivery deadline has passed (`testOpenDispute_revertsAfterDeliveryDeadline`).

### 9.7 Static analysis
Slither reports no high- or medium-severity findings. The low and informational ones are triaged in
[`SECURITY.md`](./SECURITY.md).

---

## 10. Known limitations and trade-offs

- **Trusted single arbiter.** The arbiter can decide either way within the dispute window. The
  dispute timeout protects against an *absent* arbiter, not a *malicious* one.
- **Timeouts favour the buyer.** If the seller delivers but the buyer never confirms, the seller must
  open a dispute before the delivery deadline, or anyone can refund the buyer afterwards. The
  same rule applies if the arbiter ignores a dispute. This is a deliberate choice: the
  party that has already paid is protected by default.
- **Confirmation is final.** After `confirmDelivery()` the buyer cannot dispute.
- **Binary resolution.** The arbiter cannot split funds between the parties.
- **Fee only on success.** Refunds always return 100% of the deposit. The protocol earns nothing on
  failed trades.
- **One trade per contract.** Each escrow is a separate deployment with fixed parameters.
- **ETH only.** No ERC-20 support.

---

## 11. Events

```solidity
event Deposited(address indexed buyer, uint256 amount, uint256 deliveryDeadline);
event DeliveryConfirmed(address indexed seller, uint256 amount);        // net amount to seller
event ProtocolFeeCharged(address indexed owner, uint256 fee);
event DisputeOpened(address indexed openedBy, uint256 disputeDeadline);
event DisputeResolved(address indexed recipient, bool releaseToSeller, uint256 amount);
event Refunded(address indexed buyer, uint256 amount);                  // either timeout
event Withdrawn(address indexed recipient, uint256 amount);
```

Every event carries the amounts and deadlines an off-chain indexer needs to rebuild the full
history without extra RPC calls.

---

## 12. Changelog

| Version | Changes |
|---------|---------|
| v1 | Initial escrow: deposit, confirm, dispute, delivery timeout, pull payments. |
| v2 | `DeliveryConfirmed` emits the net seller amount. |
| v3 | `disputeWindow` + `refundOnDisputeTimeout()` (absent-arbiter liveness). `openDispute()` is bounded by the delivery deadline (anti front-running). `resolveDispute()` is bounded by the dispute deadline. `ProtocolFeeCharged` event and richer `Deposited`/`DisputeOpened`/`DisputeResolved` events. `MAX_PROTOCOL_FEE_BPS` constant. `getProtocolFee()` / `getSellerPayout()` views. Full NatSpec. |
