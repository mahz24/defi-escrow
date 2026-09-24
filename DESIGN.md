# Escrow — Design

This document is the specification the contracts and the test suite are built against. Every rule
below is enforced in [`src/Escrow.sol`](./src/Escrow.sol) or [`src/EscrowFactory.sol`](./src/EscrowFactory.sol)
and covered by at least one test (unit, fuzz or invariant).

---

## 1. Architecture

```
                         ┌──────────────────────────────┐
  owner ── setFee / ───► │         EscrowFactory        │
          setRecipient   │  (Ownable2Step)              │
                         │  • i_implementation ─────────┼──► Escrow (logic contract, never initialized)
  anyone ─ createEscrow ►│  • CREATE2 clone per trade   │           ▲ delegatecall
                         │  • index by participant      │           │
                         └──────────────┬───────────────┘   ┌───────┴───────┐ ┌───────────────┐
                                        │ clone + init       │ Escrow clone  │ │ Escrow clone  │ ...
                                        └───────────────────►│ 45 bytes, own │ │ 45 bytes, own │
                                                             │ storage/funds │ │ storage/funds │
                                                             └───────────────┘ └───────────────┘
```

- **One clone per trade.** Each trade is an [EIP-1167](https://eips.ethereum.org/EIPS/eip-1167)
  minimal proxy with its own storage and funds. Trades are fully isolated: a bug or a stuck token
  in one escrow can't touch another.
- **Deterministic addresses.** The factory uses CREATE2 with `salt = keccak256(creator, userSalt)`.
  The address is known before creation, so a buyer can `approve` tokens or share the link in advance.
  Because the creator is part of the salt, nobody can squat another creator's address.
- **Protocol settings live in the factory.** The fee and fee recipient are owned by the factory
  (`Ownable2Step`) and **snapshotted** into each escrow at creation. Changing them never affects
  existing trades.
- **Assets.** Payment can be native ETH (`token == address(0)`) or any standard ERC-20.

---

## 2. Roles

| Role | Where | Responsibility |
|------|-------|----------------|
| `buyer` | escrow | Deposits the exact amount and confirms delivery. |
| `seller` | escrow | Delivers the product/service off-chain and receives the payout. |
| `arbiter` | escrow | Trusted third party that resolves disputes within the dispute window. |
| `feeRecipient` | escrow (from factory) | Receives the protocol fee when, and only when, the seller is paid. |
| factory `owner` | factory | Updates the fee (≤ 5%) and fee recipient for **future** escrows. Has no power over existing escrows. |
| anyone | both | Can create escrows and trigger the two timeout refunds (liveness). |

`buyer`, `seller` and `arbiter` must be pairwise distinct. `feeRecipient` may coincide with a party,
for example a marketplace that both arbitrates and charges the fee.

---

## 3. State machine

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

`COMPLETE` and `REFUNDED` are terminal. Afterwards only `withdraw()` / `withdrawTo()` are available.

---

## 4. Storage layout (per clone)

Clones can't use `immutable` variables, because immutables live in the implementation's bytecode.
Trade terms are therefore storage variables, written exactly once in `initialize()` and never
changed afterwards (`invariant_termsNeverChange`). They are packed into **7 slots instead of 12**,
which cuts about 20% off every escrow creation.

| Slot | Variables | Bytes |
|------|-----------|-------|
| 0 | `address s_buyer` | 20 |
| 1 | `address s_seller` | 20 |
| 2 | `address s_arbiter` | 20 |
| 3 | `address s_feeRecipient` | 20 |
| 4 | `address s_token` · `State s_state` · `uint16 s_protocolFeeBps` · `uint64 s_depositDeadline` | 31 |
| 5 | `uint32 s_deliveryWindow` · `uint32 s_disputeWindow` · `uint64 s_deliveryDeadline` · `uint64 s_disputeDeadline` | 24 |
| 6 | `uint256 s_amount` | 32 |
| — | `mapping(address => uint256) s_pendingWithdrawals` | — |

- `uint64` timestamps last until the year ~584 billion.
- `uint32` windows allow up to ~136 years. `initialize()` rejects larger windows instead of truncating them.
- `uint16` fee is capped at 500.

Views: `getProtocolFee()`, `getSellerPayout()`, `isNative()`.

---

## 5. Transition table

| Function | Caller | From | To | Time condition | Effects / events |
|----------|--------|------|----|----------------|------------------|
| `deposit()` | buyer | AWAITING_DEPOSIT | AWAITING_DELIVERY | `now <= s_depositDeadline` | ETH: `msg.value == s_amount`. ERC-20: `msg.value == 0`, pulls `s_amount` via `safeTransferFrom` and requires the balance to increase by exactly `s_amount`. Sets `s_deliveryDeadline`. Emits `Deposited` |
| `confirmDelivery()` | buyer | AWAITING_DELIVERY | COMPLETE | — | Credits seller `amount - fee` and feeRecipient `fee`. Emits `ProtocolFeeCharged`, `DeliveryConfirmed` |
| `openDispute()` | buyer or seller | AWAITING_DELIVERY | DISPUTED | `now <= s_deliveryDeadline` | Sets `s_disputeDeadline`. Emits `DisputeOpened` |
| `resolveDispute(true)` | arbiter | DISPUTED | COMPLETE | `now <= s_disputeDeadline` | Credits seller `amount - fee` and feeRecipient `fee`. Emits `ProtocolFeeCharged`, `DisputeResolved(seller, true, net)` |
| `resolveDispute(false)` | arbiter | DISPUTED | REFUNDED | `now <= s_disputeDeadline` | Credits buyer `amount`. Emits `DisputeResolved(buyer, false, amount)` |
| `refundOnTimeout()` | anyone | AWAITING_DELIVERY | REFUNDED | `now > s_deliveryDeadline` | Credits buyer `amount`. Emits `Refunded` |
| `refundOnDisputeTimeout()` | anyone | DISPUTED | REFUNDED | `now > s_disputeDeadline` | Credits buyer `amount`. Emits `Refunded` |
| `withdraw()` | credited address | COMPLETE/REFUNDED | — | — | Zeroes the caller's credit, emits `Withdrawn(caller, caller, amount)`, then sends the asset |
| `withdrawTo(to)` | credited address | COMPLETE/REFUNDED | — | — | Same as `withdraw()`, but sends the caller's own credit to `to` |

Deadline checks are inclusive for actions that must happen *before* a deadline (`deposit`,
`openDispute`, `resolveDispute`) and strict for the timeouts (`> deadline`). At every second,
exactly one side of each deadline is valid.

---

## 6. Invariants

Checked after **every random call** by the stateful fuzzing suite
([`test/invariant/`](./test/invariant)). The suite runs twice, once with ETH and once with a
6-decimals ERC-20, and each run is 256 × 500 calls, including forced donations.

| # | Invariant | Test |
|---|-----------|------|
| 1 | Nothing is credited while funds are locked. | `invariant_noCreditsBeforeFinalization` |
| 2 | held + withdrawn == deposited + donated. Nothing is ever created or lost. | `invariant_fundsAreConserved` |
| 3 | The balance equals what is owed plus donations. Donations never become claimable. | `invariant_solventAndDonationsNeverClaimable` |
| 4 | Once finalized, credited + withdrawn == `s_amount`, regardless of donations. | `invariant_finalizedEscrowAccountsForFullAmount` |
| 5 | Outcomes are exclusive. `COMPLETE` pays only seller + feeRecipient, with the exact split. `REFUNDED` pays only the buyer, in full. | `invariant_outcomesAreExclusive` |
| 6 | The state machine only moves forward, and a terminal state never changes. | `invariant_stateMachineIsMonotonic` |
| 7 | Deadlines match the state that set them. | `invariant_deadlinesAreConsistent` |
| 8 | Trade terms never change after initialization, and the fee is ≤ 5%. | `invariant_termsNeverChange` |
| 9 | `buyer`, `seller`, `arbiter` are pairwise distinct and non-zero. The token is ETH or a contract. | initialize unit tests |

---

## 7. Must-revert cases

**`initialize()` / `createEscrow()`**
- Called twice on a clone, or called on the implementation (`InvalidInitialization`).
- Any role or the fee recipient is `address(0)`.
- `buyer == seller`, `buyer == arbiter` or `seller == arbiter`.
- `token` is neither `address(0)` nor a contract.
- `amount == 0`.
- Fee > 500 bps.
- Any window is `0` or `> type(uint32).max`.
- Same creator reuses a salt (`FailedDeployment`).

**Factory admin**
- `setProtocolFee` / `setFeeRecipient` called by a non-owner.
- Fee > 500, or recipient is `address(0)`.

**Runtime**
- `deposit()`:
  - not the buyer;
  - not in `AWAITING_DEPOSIT`;
  - after the deadline;
  - ETH escrow: wrong `msg.value`;
  - ERC-20 escrow: any `msg.value`, missing allowance or balance, or fewer tokens received than `s_amount` (fee-on-transfer).
- `confirmDelivery()`: not the buyer, or not in `AWAITING_DELIVERY`.
- `openDispute()`: not buyer or seller, not in `AWAITING_DELIVERY`, or after the delivery deadline.
- `resolveDispute()`: not the arbiter, not in `DISPUTED`, or after the dispute deadline.
- `refundOnTimeout()` / `refundOnDisputeTimeout()`: wrong state, or at/before the deadline.
- `withdraw()` / `withdrawTo()`:
  - escrow not finalized;
  - nothing credited to the caller;
  - `to == address(0)`;
  - re-entrant call (`ReentrancyGuardReentrantCall`).
- Plain ETH transfers revert, because the escrow has no `receive`/`fallback`.

---

## 8. Payment pattern: pull over push

State transitions only credit `s_pendingWithdrawals`. Assets leave the contract only through
`withdraw()` / `withdrawTo()`.

- **Griefing isolation.** A seller contract that reverts on receive, or an address blocklisted by
  USDC, can't block settlement or other parties' payouts. Only its own withdrawal fails.
- **Escape hatch.** `withdrawTo(to)` lets that party move **its own** credit to another address.
  This fixes the "stuck credit" limitation of v3.

---

## 9. Security notes

### 9.1 ERC-20 handling
| Token behaviour | Handling | Test |
|---|---|---|
| No `bool` return (USDT) | `SafeERC20` | `testNoReturnToken_fullLifecycle` |
| Fee-on-transfer / deflationary | Balance-diff check in `deposit()` reverts with `Escrow__FeeOnTransferNotSupported`, so the escrow can never owe more than it holds | `testDeposit_rejectsFeeOnTransferToken` |
| Blocklists (USDC) | Pull payments + `withdrawTo()` | `testBlocklist_blockedSellerCanRedirectWithWithdrawTo` |
| Transfer hooks / re-entrancy (ERC-777-like) | `nonReentrant` (transient storage, EIP-1153) on `deposit`/`withdraw`/`withdrawTo`, plus CEI | `testReentrantToken_cannotReenterDuring*` |
| Direct transfers / donations | Accounting uses `s_amount`, never `balanceOf`. Donations stay in the contract and are never claimable | `testDonationBeforeDepositDoesNotBreakAccounting`, invariant 3 |
| Rebasing tokens (stETH, AMPL) | **Not supported.** The balance can drift away from `s_amount` after deposit | documented limitation |

### 9.2 Clones and initialization
- The implementation calls `_disableInitializers()` in its constructor, so it can never be initialized or hijacked.
- The factory clones and initializes **in the same transaction**, so there is no front-running window.
- `initializer` makes a second `initialize()` on a clone revert.
- Each clone is fully validated on its own (defense in depth), including clones created outside the factory.

### 9.3 Reentrancy
- Every external call happens after state changes (CEI).
- `nonReentrant` uses `ReentrancyGuardTransient` (EIP-1153 transient storage, cheaper than the storage-based guard).
- It is proven by two scenarios:
  - an ETH receiver that re-enters `withdraw()`;
  - a malicious token whose hook re-enters during `deposit()` and during `withdraw()`.

### 9.4 ETH transfer method
`call{value: amount}("")`, with the result checked, so smart-contract wallets (Safe, ERC-4337)
are supported.

### 9.5 Forced ETH / donated tokens
The contract never uses `address(this).balance` or `balanceOf` for accounting, except as a
*difference* measured around the deposit transfer. The invariant suite continuously injects
donations to prove this.

### 9.6 Timestamp dependence
Validators can skew the timestamp by a few seconds, which is negligible against windows measured
in days. Boundaries (`deadline` vs `deadline + 1`) are unit- and fuzz-tested.

### 9.7 Liveness: funds can never be locked forever
| Stuck party | Escape hatch |
|---|---|
| Buyer never deposits | Nothing at risk. The escrow expires. |
| Buyer disappears | `refundOnTimeout()`, callable by anyone. |
| Arbiter disappears | `refundOnDisputeTimeout()`, callable by anyone. |
| Recipient can't receive | `withdrawTo()` to another address. |

### 9.8 Front-running
- `openDispute()` is closed after the delivery deadline, so a seller can't front-run the buyer's refund.
- CREATE2 salts are bound to the creator, so nobody can squat a predicted escrow address.

### 9.9 Static analysis
Slither reports no high- or medium-severity findings. The low and informational ones are triaged in
[`SECURITY.md`](./SECURITY.md).

---

## 10. Known limitations and trade-offs

- **The arbiter is trusted.** Timeouts protect against an *absent* arbiter, not a *malicious* one.
- **Timeouts favour the buyer.** A seller who delivered but never got a confirmation must open a
  dispute before the delivery deadline. This deliberately protects the party that has already paid.
- **Confirmation is final.** After `confirmDelivery()` the buyer can't dispute.
- **Binary resolution.** The arbiter can't split funds.
- **Fee only on success.** Refunds always return 100%.
- **Rebasing tokens aren't supported, and fee-on-transfer tokens are rejected at deposit.**
- **Participant index can grow without bound.** The factory's per-participant arrays are append-only.
  Views are paginated, and nothing on-chain iterates over them.

---

## 11. Events

```solidity
// Escrow
event EscrowInitialized(address indexed buyer, address indexed seller, address indexed arbiter, address token, uint256 amount);
event Deposited(address indexed buyer, uint256 amount, uint256 deliveryDeadline);
event DeliveryConfirmed(address indexed seller, uint256 amount);          // net amount to seller
event ProtocolFeeCharged(address indexed feeRecipient, uint256 fee);
event DisputeOpened(address indexed openedBy, uint256 disputeDeadline);
event DisputeResolved(address indexed recipient, bool releaseToSeller, uint256 amount);
event Refunded(address indexed buyer, uint256 amount);                    // either timeout
event Withdrawn(address indexed account, address indexed to, uint256 amount);

// EscrowFactory
event EscrowCreated(address indexed escrow, address indexed buyer, address indexed seller,
                    address arbiter, address token, uint256 amount, uint256 protocolFeeBps);
event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
```

`EscrowCreated` alone is enough for an indexer to discover every trade and its parties. The
per-escrow events then rebuild each trade's full history.

---

## 12. Changelog

| Version | Changes |
|---------|---------|
| v1 | Initial escrow: deposit, confirm, dispute, delivery timeout, pull payments. |
| v2 | `DeliveryConfirmed` emits the net seller amount. |
| v3 | `disputeWindow` + `refundOnDisputeTimeout()` (absent-arbiter liveness). `openDispute()` bounded by the delivery deadline (anti front-running). Richer events. NatSpec. |
| v4 | **`EscrowFactory` with EIP-1167 clones:** CREATE2 predictable addresses bound to the creator, per-participant index, `Ownable2Step` protocol fee settings snapshotted per escrow. **ERC-20 support:** `SafeERC20`, fee-on-transfer rejection, `withdrawTo()` escape hatch for blocklisted or non-receiving recipients. **Other:** `ReentrancyGuardTransient`, storage packed 12 → 7 slots, `owner` renamed to `feeRecipient`, Solidity 0.8.28 (Cancun). |
