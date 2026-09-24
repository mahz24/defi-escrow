# Security

> **Disclaimer:** this is a portfolio project. It has **not** been audited by a third party and
> should not hold real funds on mainnet.

## Reporting a vulnerability

Please open a [private security advisory](https://github.com/mahz24/defi-escrow/security/advisories/new)
instead of a public issue.

---

## Self-review summary

| Area | Approach | Evidence |
|------|----------|----------|
| Access control | Role modifiers on every state-changing function; `Ownable2Step` on the factory | Unit tests + `testFuzz_onlyBuyerCanDeposit`, `testFuzz_onlyArbiterCanResolve`, `testFuzz_outsidersCannotActOnEscrow`, `testSetProtocolFee_onlyOwner` |
| Initialization | `_disableInitializers()` on the implementation; clone + initialize atomically in the factory | `testImplementationCannotBeInitialized`, `testCloneCannotBeReinitialized` |
| State machine | `inState` modifier; monotonic transitions | `invariant_stateMachineIsMonotonic` |
| Accounting | `s_amount` is the only source of truth; pull payments | `invariant_fundsAreConserved`, `invariant_solventAndDonationsNeverClaimable`, `invariant_outcomesAreExclusive` (ETH **and** ERC-20) |
| Fee math | Integer bps with a 5% cap. Rounding goes against the fee, never the seller. | `testFuzz_feeSplitIsExactAndCapped` (amounts up to 1e30, both assets) |
| ERC-20 quirks | `SafeERC20` + balance-diff check + `withdrawTo()` | USDT-like, fee-on-transfer, USDC-blocklist and donation tests |
| Reentrancy | CEI + `ReentrancyGuardTransient` | `testWithdraw_reentrancyIsBlocked` (ETH), `testReentrantToken_cannotReenterDuringDeposit/Withdraw` |
| Griefing / DoS | Pull payments isolate failing receivers; `withdrawTo()` rescues them | `testWithdraw_rejectingReceiverOnlyHurtsItself`, `testWithdrawTo_rescuesRejectingReceiver` |
| Liveness | Two permissionless timeouts | `testRefundOnTimeout_*`, `testRefundOnDisputeTimeout_*`, `testDeployedFactory_erc20AbsentArbiterCannotLockFunds` |
| Front-running | `openDispute()` bounded by the delivery deadline; CREATE2 salt bound to the creator | `testOpenDispute_revertsAfterDeliveryDeadline`, `testCreateEscrow_saltIsBoundToCreator` |
| Boundaries | Exact deadline and deadline+1 tested for every time check; `uint32` window overflow rejected | `*_succeedsExactlyAt*`, `*_revertsAfter*`, `testInit_revertsIfWindowsOverflowUint32` |

### Mutation check
To make sure the invariant suite doesn't pass by accident, the fee credit was mutated by hand
(`feeRecipient += fee + 1`). **All 16 invariant checks failed** (8 for ETH, 8 for ERC-20). Some
failed on accounting assertions. Others failed because the over-credited escrow became
insolvent and a later withdrawal reverted, which the handler treats as a failure
(`fail_on_revert = true`).

---

## Threat model

| Actor | What they could try | Mitigation |
|-------|---------------------|------------|
| Malicious buyer | Get the goods and a refund | A refund needs a timeout (no confirmation) or the arbiter. The seller must dispute before the delivery deadline. Documented trade-off. |
| Malicious seller | Freeze funds by disputing and hoping the arbiter vanishes | `refundOnDisputeTimeout()` |
| Malicious seller | Front-run `refundOnTimeout()` with `openDispute()` | `openDispute()` reverts after the delivery deadline |
| Malicious receiver contract | Revert on receive to block settlement | Pull payments. Only its own withdrawal fails. |
| Malicious receiver / token hook | Re-enter `withdraw()` or `deposit()` | CEI + `nonReentrant` |
| Malicious token (chosen by the creator) | Report fake transfers or charge fees | Balance-diff check at deposit. Parties choose the token, and a clone only ever holds that token. |
| Blocklisting token issuer | Block the seller's address | `withdrawTo()` to a clean address. Other parties are unaffected. |
| Absent arbiter | Lock disputed funds forever | `refundOnDisputeTimeout()` |
| Malicious arbiter | Rule unfairly | **Not mitigated.** The arbiter is a trusted role. |
| Anyone | Hijack the implementation or re-initialize a clone | `_disableInitializers()`, `initializer` |
| Anyone | Squat a predicted escrow address | Salt = `keccak256(creator, salt)` |
| Anyone | Donate ETH/tokens to skew accounting | Balance is never used for accounting |
| Factory owner | Change the fee on live trades, or set an abusive fee | Fee snapshotted per escrow; hard cap 500 bps; no admin power over clones |
| Validator | Skew `block.timestamp` by seconds | Windows are days long; boundaries are tested |

---

## Slither triage

`slither .` (config in [`slither.config.json`](./slither.config.json)) reports **no high or medium
findings**. CI fails on any finding of medium severity or above. The remaining findings were each
reviewed:

| Detector | Location | Status | Rationale |
|----------|----------|--------|-----------|
| `timestamp` (low) | deadline comparisons | Accepted | Deadlines are the business logic. Drift of a few seconds is irrelevant at day scale. |
| `low-level-calls` | `_withdraw()` | Accepted | `call` is required to support smart-contract wallets. The return value is checked. |
| `cyclomatic-complexity` | `initialize()` | Accepted | Linear input validation, one check per parameter. |
| `naming-convention` | `i_` / `s_` prefixes | Excluded | Intentional convention that makes immutables and storage reads visible at the call site. |

`reentrancy-benign` and `reentrancy-events` were reported on `EscrowFactory.createEscrow` in an
early draft. They were fixed by writing the index and emitting `EscrowCreated` *before* calling
`initialize()` on the new clone.

---

## Known limitations

See [`DESIGN.md` §10](./DESIGN.md#10-known-limitations-and-trade-offs).
