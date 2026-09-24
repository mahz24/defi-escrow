// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Test } from "forge-std/Test.sol";
import { Escrow } from "../../src/Escrow.sol";

/// @notice Drives the Escrow through random, *valid* sequences of actions by every role,
///         interleaved with time jumps. Ghost variables record what happened so the invariant
///         suite can compare the contract's accounting against an independent model.
contract EscrowHandler is Test {
    Escrow public escrow;
    address public buyer;
    address public seller;
    address public arbiter;
    address public owner;

    // Ghost variables
    bool public ghost_deposited;
    uint256 public ghost_totalWithdrawn;
    mapping(address => uint256) public ghost_withdrawnBy;
    uint256 public ghost_maxStateRank;
    bool public ghost_stateWentBackwards;
    bool public ghost_terminalStateChanged;
    Escrow.State public ghost_firstTerminalState;
    bool public ghost_reachedTerminal;

    mapping(bytes32 => uint256) public calls;

    modifier track(bytes32 name) {
        calls[name]++;
        _;
        _recordState();
    }

    constructor(Escrow _escrow) {
        escrow = _escrow;
        buyer = _escrow.i_buyer();
        seller = _escrow.i_seller();
        arbiter = _escrow.i_arbiter();
        owner = _escrow.i_owner();
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/
    function deposit() external track("deposit") {
        if (escrow.s_state() != Escrow.State.AWAITING_DEPOSIT) return;
        if (block.timestamp > escrow.i_depositDeadline()) return;

        uint256 amount = escrow.i_expectedAmount();
        vm.deal(buyer, buyer.balance + amount);
        vm.prank(buyer);
        escrow.deposit{ value: amount }();
        ghost_deposited = true;
    }

    function confirmDelivery() external track("confirmDelivery") {
        if (escrow.s_state() != Escrow.State.AWAITING_DELIVERY) return;
        vm.prank(buyer);
        escrow.confirmDelivery();
    }

    function openDispute(bool bySeller) external track("openDispute") {
        if (escrow.s_state() != Escrow.State.AWAITING_DELIVERY) return;
        if (block.timestamp > escrow.s_deliveryDeadline()) return;
        vm.prank(bySeller ? seller : buyer);
        escrow.openDispute();
    }

    function resolveDispute(bool releaseToSeller) external track("resolveDispute") {
        if (escrow.s_state() != Escrow.State.DISPUTED) return;
        if (block.timestamp > escrow.s_disputeDeadline()) return;
        vm.prank(arbiter);
        escrow.resolveDispute(releaseToSeller);
    }

    function refundOnTimeout(address caller) external track("refundOnTimeout") {
        if (escrow.s_state() != Escrow.State.AWAITING_DELIVERY) return;
        if (block.timestamp <= escrow.s_deliveryDeadline()) return;
        vm.prank(caller);
        escrow.refundOnTimeout();
    }

    function refundOnDisputeTimeout(address caller) external track("refundOnDisputeTimeout") {
        if (escrow.s_state() != Escrow.State.DISPUTED) return;
        if (block.timestamp <= escrow.s_disputeDeadline()) return;
        vm.prank(caller);
        escrow.refundOnDisputeTimeout();
    }

    function withdraw(uint256 actorSeed) external track("withdraw") {
        Escrow.State s = escrow.s_state();
        if (s != Escrow.State.COMPLETE && s != Escrow.State.REFUNDED) return;

        address actor = _actor(actorSeed);
        uint256 pending = escrow.s_pendingWithdrawals(actor);
        if (pending == 0) return;

        uint256 balanceBefore = actor.balance;
        vm.prank(actor);
        escrow.withdraw();

        assertEq(actor.balance - balanceBefore, pending, "withdraw paid a wrong amount");
        ghost_totalWithdrawn += pending;
        ghost_withdrawnBy[actor] += pending;
    }

    function warp(uint256 seconds_) external track("warp") {
        vm.warp(block.timestamp + bound(seconds_, 1, 10 days));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function _actor(uint256 seed) internal view returns (address) {
        uint256 i = seed % 3;
        if (i == 0) return buyer;
        if (i == 1) return seller;
        return owner;
    }

    function _rank(Escrow.State s) internal pure returns (uint256) {
        if (s == Escrow.State.AWAITING_DEPOSIT) return 0;
        if (s == Escrow.State.AWAITING_DELIVERY) return 1;
        if (s == Escrow.State.DISPUTED) return 2;
        return 3; // COMPLETE or REFUNDED
    }

    function _recordState() internal {
        Escrow.State s = escrow.s_state();
        uint256 r = _rank(s);
        if (r < ghost_maxStateRank) ghost_stateWentBackwards = true;
        if (r > ghost_maxStateRank) ghost_maxStateRank = r;

        if (r == 3) {
            if (!ghost_reachedTerminal) {
                ghost_reachedTerminal = true;
                ghost_firstTerminalState = s;
            } else if (s != ghost_firstTerminalState) {
                ghost_terminalStateChanged = true;
            }
        }
    }
}
