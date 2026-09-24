// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Escrow } from "../../src/Escrow.sol";
import { EscrowLifecycleTests } from "./EscrowLifecycleTests.sol";
import { RejectingReceiver } from "../mocks/RejectingReceiver.sol";
import { ReentrantReceiver } from "../mocks/ReentrantReceiver.sol";

/// @notice Runs the full lifecycle suite with native ETH, plus ETH-specific edge cases.
contract EscrowEthTest is EscrowLifecycleTests {
    function _deployToken() internal pure override returns (address) {
        return address(0);
    }

    function _amount() internal pure override returns (uint256) {
        return 1 ether;
    }

    function testDeposit_revertsIfNoValue() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.Escrow__WrongPaymentAmount.selector, 0, _amount()));
        escrow.deposit();
    }

    function testDeposit_revertsIfValueTooHigh() public {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.Escrow__WrongPaymentAmount.selector, 2 ether, _amount()));
        escrow.deposit{ value: 2 ether }();
    }

    function testDirectEthTransferReverts() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        (bool success,) = address(escrow).call{ value: 1 ether }("");
        assertFalse(success);
    }

    function testWithdraw_rejectingReceiverOnlyHurtsItself() public {
        RejectingReceiver rejectingSeller = new RejectingReceiver();
        Escrow.EscrowParams memory p = _params();
        p.seller = address(rejectingSeller);
        Escrow target = _create(p);

        _depositInto(target);
        vm.prank(buyer);
        target.confirmDelivery();

        vm.prank(address(rejectingSeller));
        vm.expectRevert(Escrow.Escrow__WithdrawalFailed.selector);
        target.withdraw();

        // Its credit is preserved and the fee recipient is unaffected.
        assertEq(target.s_pendingWithdrawals(address(rejectingSeller)), _sellerAmount());
        vm.prank(feeRecipient);
        target.withdraw();
        assertEq(feeRecipient.balance, _fee());
    }

    function testWithdrawTo_rescuesRejectingReceiver() public {
        RejectingReceiver rejectingSeller = new RejectingReceiver();
        Escrow.EscrowParams memory p = _params();
        p.seller = address(rejectingSeller);
        Escrow target = _create(p);

        _depositInto(target);
        vm.prank(buyer);
        target.confirmDelivery();

        address rescue = makeAddr("rescue");
        vm.prank(address(rejectingSeller));
        target.withdrawTo(rescue);

        assertEq(rescue.balance, _sellerAmount());
        assertEq(target.s_pendingWithdrawals(address(rejectingSeller)), 0);
    }

    function testWithdraw_reentrancyIsBlocked() public {
        ReentrantReceiver attacker = new ReentrantReceiver();
        Escrow.EscrowParams memory p = _params();
        p.seller = address(attacker);
        Escrow target = _create(p);
        attacker.setTarget(target);

        _depositInto(target);
        vm.prank(buyer);
        target.confirmDelivery();

        attacker.attack();

        // The re-entrant withdraw() was rejected; the attacker was paid exactly once.
        assertEq(address(attacker).balance, _sellerAmount());
        assertEq(attacker.reentryAttempts(), 1);
        assertFalse(attacker.reentrySucceeded());
        assertEq(address(target).balance, _fee());
    }
}
