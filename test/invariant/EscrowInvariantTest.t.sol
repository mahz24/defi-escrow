// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { Escrow } from "../../src/Escrow.sol";
import { EscrowHandler } from "./EscrowHandler.t.sol";

/// @notice Stateful fuzzing of the invariants documented in DESIGN.md.
/// @dev Foundry calls random handler actions in random order (with time warps in between)
///      and checks every `invariant_*` function after each call.
contract EscrowInvariantTest is StdInvariant, Test {
    Escrow escrow;
    EscrowHandler handler;

    uint256 constant AMOUNT = 1 ether;
    uint256 constant FEE_BPS = 250;

    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address arbiter = makeAddr("arbiter");
    address owner = makeAddr("owner");

    function setUp() public {
        escrow = new Escrow(buyer, seller, arbiter, owner, AMOUNT, FEE_BPS, 1 days, 7 days, 3 days);
        handler = new EscrowHandler(escrow);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = EscrowHandler.deposit.selector;
        selectors[1] = EscrowHandler.confirmDelivery.selector;
        selectors[2] = EscrowHandler.openDispute.selector;
        selectors[3] = EscrowHandler.resolveDispute.selector;
        selectors[4] = EscrowHandler.refundOnTimeout.selector;
        selectors[5] = EscrowHandler.refundOnDisputeTimeout.selector;
        selectors[6] = EscrowHandler.withdraw.selector;
        selectors[7] = EscrowHandler.warp.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function _sumPending() internal view returns (uint256) {
        return
            escrow.s_pendingWithdrawals(buyer) + escrow.s_pendingWithdrawals(seller)
                + escrow.s_pendingWithdrawals(owner);
    }

    function _isFinalized() internal view returns (bool) {
        Escrow.State s = escrow.s_state();
        return s == Escrow.State.COMPLETE || s == Escrow.State.REFUNDED;
    }

    /// Conservation: ETH still held + ETH paid out == ETH deposited. No wei created or lost.
    function invariant_fundsAreConserved() public view {
        uint256 deposited = handler.ghost_deposited() ? AMOUNT : 0;
        assertEq(address(escrow).balance + handler.ghost_totalWithdrawn(), deposited);
    }

    /// Solvency: the contract always holds exactly what it owes.
    function invariant_balanceEqualsOwed() public view {
        uint256 owed = _isFinalized() ? _sumPending() : (handler.ghost_deposited() ? AMOUNT : 0);
        assertEq(address(escrow).balance, owed);
    }

    /// DESIGN.md #1: nothing is credited while funds are locked.
    function invariant_noCreditsBeforeFinalization() public view {
        if (!_isFinalized()) assertEq(_sumPending(), 0);
    }

    /// DESIGN.md #4: once finalized, credited + withdrawn == expectedAmount.
    function invariant_finalizedEscrowAccountsForFullAmount() public view {
        if (_isFinalized()) assertEq(_sumPending() + handler.ghost_totalWithdrawn(), AMOUNT);
    }

    /// Outcomes are mutually exclusive: COMPLETE pays seller+owner only, REFUNDED pays buyer only.
    function invariant_outcomesAreExclusive() public view {
        Escrow.State s = escrow.s_state();
        uint256 buyerTotal = escrow.s_pendingWithdrawals(buyer) + handler.ghost_withdrawnBy(buyer);
        uint256 sellerTotal = escrow.s_pendingWithdrawals(seller) + handler.ghost_withdrawnBy(seller);
        uint256 ownerTotal = escrow.s_pendingWithdrawals(owner) + handler.ghost_withdrawnBy(owner);

        if (s == Escrow.State.COMPLETE) {
            assertEq(buyerTotal, 0);
            assertEq(ownerTotal, escrow.getProtocolFee());
            assertEq(sellerTotal, escrow.getSellerPayout());
        } else if (s == Escrow.State.REFUNDED) {
            assertEq(buyerTotal, AMOUNT);
            assertEq(sellerTotal + ownerTotal, 0);
        }
    }

    /// The state machine only moves forward, and a terminal state is final.
    function invariant_stateMachineIsMonotonic() public view {
        assertFalse(handler.ghost_stateWentBackwards());
        assertFalse(handler.ghost_terminalStateChanged());
    }

    /// Deadlines are consistent with the state that set them.
    function invariant_deadlinesAreConsistent() public view {
        Escrow.State s = escrow.s_state();
        if (s == Escrow.State.AWAITING_DEPOSIT) assertEq(escrow.s_deliveryDeadline(), 0);
        if (escrow.s_disputeDeadline() != 0) {
            assertGt(escrow.s_deliveryDeadline(), 0);
            assertLe(escrow.s_disputeDeadline(), escrow.s_deliveryDeadline() + escrow.i_disputeWindow());
        }
    }

    /// DESIGN.md #5: fee cap holds.
    function invariant_feeWithinCap() public view {
        assertLe(escrow.i_protocolFeeBps(), escrow.MAX_PROTOCOL_FEE_BPS());
    }

    function afterInvariant() external view {
        // Sanity: make sure the campaign actually exercised the state machine.
        assertGt(handler.calls("deposit"), 0);
    }
}
