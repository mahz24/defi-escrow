// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Escrow } from "../../src/Escrow.sol";
import { EscrowFactory } from "../../src/EscrowFactory.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { EscrowHandler } from "./EscrowHandler.t.sol";

/// @notice Stateful fuzzing of the invariants documented in DESIGN.md.
/// @dev Foundry calls random handler actions in random order (with time warps and donations in between)
///      and checks every `invariant_*` function after each call. The suite runs twice: ETH and ERC-20.
abstract contract EscrowInvariantBase is StdInvariant, Test {
    Escrow escrow;
    EscrowHandler handler;

    uint256 constant FEE_BPS = 250;

    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address arbiter = makeAddr("arbiter");
    address feeRecipient = makeAddr("feeRecipient");

    function _token() internal virtual returns (address);
    function _amount() internal pure virtual returns (uint256);

    function setUp() public {
        EscrowFactory factory = new EscrowFactory(address(this), feeRecipient, FEE_BPS);
        Escrow.EscrowParams memory p = Escrow.EscrowParams({
            buyer: buyer,
            seller: seller,
            arbiter: arbiter,
            token: _token(),
            amount: _amount(),
            depositWindow: 1 days,
            deliveryWindow: 7 days,
            disputeWindow: 3 days
        });
        escrow = Escrow(factory.createEscrow(p, bytes32(0)));
        handler = new EscrowHandler(escrow);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = EscrowHandler.deposit.selector;
        selectors[1] = EscrowHandler.confirmDelivery.selector;
        selectors[2] = EscrowHandler.openDispute.selector;
        selectors[3] = EscrowHandler.resolveDispute.selector;
        selectors[4] = EscrowHandler.refundOnTimeout.selector;
        selectors[5] = EscrowHandler.refundOnDisputeTimeout.selector;
        selectors[6] = EscrowHandler.withdraw.selector;
        selectors[7] = EscrowHandler.donate.selector;
        selectors[8] = EscrowHandler.warp.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function _escrowBalance() internal view returns (uint256) {
        address t = escrow.s_token();
        return t == address(0) ? address(escrow).balance : IERC20(t).balanceOf(address(escrow));
    }

    function _sumPending() internal view returns (uint256) {
        return escrow.s_pendingWithdrawals(buyer) + escrow.s_pendingWithdrawals(seller)
            + escrow.s_pendingWithdrawals(feeRecipient);
    }

    function _isFinalized() internal view returns (bool) {
        Escrow.State s = escrow.s_state();
        return s == Escrow.State.COMPLETE || s == Escrow.State.REFUNDED;
    }

    /// Conservation: held + paid out == deposited + donated. Nothing is created or lost.
    function invariant_fundsAreConserved() public view {
        uint256 deposited = handler.ghost_deposited() ? _amount() : 0;
        assertEq(_escrowBalance() + handler.ghost_totalWithdrawn(), deposited + handler.ghost_donated());
    }

    /// Solvency: the escrow always holds at least what it owes; donations are the only surplus
    /// and never become claimable by anyone.
    function invariant_solventAndDonationsNeverClaimable() public view {
        uint256 owed = _isFinalized() ? _sumPending() : (handler.ghost_deposited() ? _amount() : 0);
        assertEq(_escrowBalance(), owed + handler.ghost_donated());
    }

    /// Nothing is credited while funds are locked.
    function invariant_noCreditsBeforeFinalization() public view {
        if (!_isFinalized()) assertEq(_sumPending(), 0);
    }

    /// Once finalized, credited + withdrawn == s_amount, regardless of donations.
    function invariant_finalizedEscrowAccountsForFullAmount() public view {
        if (_isFinalized()) assertEq(_sumPending() + handler.ghost_totalWithdrawn(), _amount());
    }

    /// Outcomes are mutually exclusive: COMPLETE pays seller + fee only, REFUNDED pays the buyer only.
    function invariant_outcomesAreExclusive() public view {
        Escrow.State s = escrow.s_state();
        uint256 buyerTotal = escrow.s_pendingWithdrawals(buyer) + handler.ghost_withdrawnBy(buyer);
        uint256 sellerTotal = escrow.s_pendingWithdrawals(seller) + handler.ghost_withdrawnBy(seller);
        uint256 feeTotal = escrow.s_pendingWithdrawals(feeRecipient) + handler.ghost_withdrawnBy(feeRecipient);

        if (s == Escrow.State.COMPLETE) {
            assertEq(buyerTotal, 0);
            assertEq(feeTotal, escrow.getProtocolFee());
            assertEq(sellerTotal, escrow.getSellerPayout());
        } else if (s == Escrow.State.REFUNDED) {
            assertEq(buyerTotal, _amount());
            assertEq(sellerTotal + feeTotal, 0);
        }
    }

    /// The state machine only moves forward, and a terminal state is final.
    function invariant_stateMachineIsMonotonic() public view {
        assertFalse(handler.ghost_stateWentBackwards());
        assertFalse(handler.ghost_terminalStateChanged());
    }

    /// Deadlines are consistent with the state that set them.
    function invariant_deadlinesAreConsistent() public view {
        if (escrow.s_state() == Escrow.State.AWAITING_DEPOSIT) assertEq(escrow.s_deliveryDeadline(), 0);
        if (escrow.s_disputeDeadline() != 0) {
            assertGt(escrow.s_deliveryDeadline(), 0);
            assertLe(escrow.s_disputeDeadline(), escrow.s_deliveryDeadline() + escrow.s_disputeWindow());
        }
    }

    /// Trade terms are immutable after initialization.
    function invariant_termsNeverChange() public view {
        assertEq(escrow.s_buyer(), buyer);
        assertEq(escrow.s_seller(), seller);
        assertEq(escrow.s_arbiter(), arbiter);
        assertEq(escrow.s_feeRecipient(), feeRecipient);
        assertEq(escrow.s_amount(), _amount());
        assertEq(escrow.s_protocolFeeBps(), FEE_BPS);
        assertLe(escrow.s_protocolFeeBps(), escrow.MAX_PROTOCOL_FEE_BPS());
    }

    function afterInvariant() external view {
        // Sanity: make sure the campaign actually exercised the state machine.
        assertGt(handler.calls("deposit"), 0);
    }
}

contract EscrowEthInvariantTest is EscrowInvariantBase {
    function _token() internal pure override returns (address) {
        return address(0);
    }

    function _amount() internal pure override returns (uint256) {
        return 1 ether;
    }
}

contract EscrowErc20InvariantTest is EscrowInvariantBase {
    function _token() internal override returns (address) {
        return address(new MockERC20("Mock USD", "mUSD", 6));
    }

    function _amount() internal pure override returns (uint256) {
        return 1000e6;
    }
}
