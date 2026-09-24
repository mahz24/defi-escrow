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
| Access control | Role modifiers on every state-changing function | Unit tests + `testFuzz_onlyBuyerCanDeposit`, `testFuzz_onlyArbiterCanResolve`, `testFuzz_outsidersCannotActOnEscrow` |
| State machine | `inState` modifier; monotonic transitions | `invariant_stateMachineIsMonotonic` |
| Accounting | Immutable amount as the source of truth; pull payments | `invariant_fundsAreConserved`, `invariant_balanceEqualsOwed`, `invariant_outcomesAreExclusive` |
| Fee math | Integer bps with a 5% cap. Rounding goes against the fee, never the seller. | `testFuzz_feeSplitIsExactAndCapped` (amounts up to 1e30) |
| Reentrancy | Strict CEI in `withdraw()`, the only external call | `testWithdraw_reentrancyCannotDoubleSpend` |
| Griefing / DoS | Pull payments isolate failing receivers | `testWithdraw_revertsIfCallFails` |
| Liveness | Two permissionless timeouts | `testRefundOnTimeout_*`, `testRefundOnDisputeTimeout_*`, `testDeployedEscrow_absentArbiterCannotLockFunds` |
| Front-running | `openDispute()` bounded by the delivery deadline | `testOpenDispute_revertsAfterDeliveryDeadline` |
| Boundaries | Exact deadline and deadline+1 tested for every time check | `*_succeedsExactlyAt*`, `*_revertsAfter*`, fuzzed deadlines |

### Mutation check
To make sure the invariant suite is not passing by accident, the fee credit was mutated by
hand (`owner += fee + 1`). Three invariants failed immediately (`fundsAreConserved`,
`balanceEqualsOwed`, `outcomesAreExclusive`).

---

## Threat model

| Actor | What they could try | Mitigation |
|-------|---------------------|------------|
| Malicious buyer | Get the goods and a refund | Buyer can only get a refund via timeout (no confirmation) or the arbiter. The seller must open a dispute before the delivery deadline. Documented trade-off. |
| Malicious seller | Freeze funds by disputing and hoping the arbiter vanishes | `refundOnDisputeTimeout()` |
| Malicious seller | Front-run `refundOnTimeout()` with `openDispute()` | `openDispute()` reverts after the delivery deadline |
| Malicious seller contract | Revert on receive to block settlement | Pull payments. Only the seller's own withdrawal fails. |
| Malicious seller contract | Re-enter `withdraw()` | CEI: the credit is zeroed before the call |
| Absent arbiter | Lock disputed funds forever | `refundOnDisputeTimeout()` |
| Malicious arbiter | Rule unfairly | **Not mitigated.** The arbiter is a trusted role (see Known limitations). |
| Anyone | Force ETH in via `selfdestruct` | Balance is never read for logic |
| Validator | Skew `block.timestamp` by seconds | Windows are days long. Boundaries are tested. |
| Deployer | Set an abusive fee | Hard cap `MAX_PROTOCOL_FEE_BPS = 500` |

---

## Slither triage

`slither .` (config in [`slither.config.json`](./slither.config.json)) reports **no high or medium
findings**. CI fails on any finding of medium severity or above. The remaining low and
informational findings were each reviewed:

| Detector | Location | Status | Rationale |
|----------|----------|--------|-----------|
| `timestamp` (low) | deadline comparisons | Accepted | Deadlines are the business logic. Drift of a few seconds is irrelevant at day scale. |
| `low-level-calls` | `withdraw()` | Accepted | `call` is required to support smart-contract wallets. The return value is checked. |
| `solc-version` | `pragma 0.8.19` | Accepted | The listed compiler bugs affect `verbatim`, the IR inliner and `.selector` side-effects. None of these features are used, and the contract is compiled with the legacy pipeline. |
| `cyclomatic-complexity` | constructor | Accepted | Linear input validation, one check per parameter. |
| `naming-convention` | `i_` / `s_` prefixes | Excluded | Intentional convention that makes immutables and storage reads visible at the call site. |

---

## Known limitations

See [`DESIGN.md` §10](./DESIGN.md#10-known-limitations-and-trade-offs).
