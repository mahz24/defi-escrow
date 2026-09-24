// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Escrow } from "../../src/Escrow.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Drives one Escrow (ETH or ERC-20) through random, *valid* sequences of actions by every role,
///         interleaved with time jumps and unsolicited donations. Ghost variables record what happened so the
///         invariant suite can compare the contract's accounting against an independent model.
contract EscrowHandler is Test {
    Escrow public escrow;
    address public token; // address(0) = ETH
    address public buyer;
    address public seller;
    address public arbiter;
    address public feeRecipient;
    address public sink = makeAddr("withdrawToSink");

    // Ghost variables
    bool public ghost_deposited;
    uint256 public ghost_donated;
    uint256 public ghost_totalWithdrawn;
    mapping(address => uint256) public ghost_withdrawnBy;
    uint256 public ghost_maxStateRank;
    bool public ghost_stateWentBackwards;
    bool public ghost_terminalStateChanged;
    bool public ghost_reachedTerminal;
    Escrow.State public ghost_firstTerminalState;

    mapping(bytes32 => uint256) public calls;

    modifier track(bytes32 name) {
        calls[name]++;
        _;
        _recordState();
    }

    constructor(Escrow _escrow) {
        escrow = _escrow;
        token = _escrow.s_token();
        buyer = _escrow.s_buyer();
        seller = _escrow.s_seller();
        arbiter = _escrow.s_arbiter();
        feeRecipient = _escrow.s_feeRecipient();
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/
    function deposit() external track("deposit") {
        if (escrow.s_state() != Escrow.State.AWAITING_DEPOSIT) return;
        if (block.timestamp > escrow.s_depositDeadline()) return;

        uint256 amount = escrow.s_amount();
        if (token == address(0)) {
            vm.deal(buyer, buyer.balance + amount);
            vm.prank(buyer);
            escrow.deposit{ value: amount }();
        } else {
            MockERC20(token).mint(buyer, amount);
            vm.startPrank(buyer);
            IERC20(token).approve(address(escrow), amount);
            escrow.deposit();
            vm.stopPrank();
        }
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

    function withdraw(uint256 actorSeed, bool toSink) external track("withdraw") {
        Escrow.State s = escrow.s_state();
        if (s != Escrow.State.COMPLETE && s != Escrow.State.REFUNDED) return;

        address actor = _actor(actorSeed);
        uint256 pending = escrow.s_pendingWithdrawals(actor);
        if (pending == 0) return;

        address recipient = toSink ? sink : actor;
        uint256 balanceBefore = _balance(recipient);
        vm.prank(actor);
        if (toSink) escrow.withdrawTo(sink);
        else escrow.withdraw();

        assertEq(_balance(recipient) - balanceBefore, pending, "withdraw paid a wrong amount");
        ghost_totalWithdrawn += pending;
        ghost_withdrawnBy[actor] += pending;
    }

    /// @dev Unsolicited funds: forced ETH (as via selfdestruct/coinbase) or a direct token transfer.
    function donate(uint256 amount) external track("donate") {
        amount = bound(amount, 1, 1e24);
        if (token == address(0)) {
            vm.deal(address(escrow), address(escrow).balance + amount);
        } else {
            MockERC20(token).mint(address(escrow), amount);
        }
        ghost_donated += amount;
    }

    function warp(uint256 seconds_) external track("warp") {
        vm.warp(block.timestamp + bound(seconds_, 1, 10 days));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function _balance(address who) internal view returns (uint256) {
        return token == address(0) ? who.balance : IERC20(token).balanceOf(who);
    }

    function _actor(uint256 seed) internal view returns (address) {
        uint256 i = seed % 3;
        if (i == 0) return buyer;
        if (i == 1) return seller;
        return feeRecipient;
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
