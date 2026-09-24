// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Escrow } from "../../src/Escrow.sol";
import { EscrowLifecycleTests } from "./EscrowLifecycleTests.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { FeeOnTransferToken } from "../mocks/FeeOnTransferToken.sol";
import { NoReturnToken } from "../mocks/NoReturnToken.sol";
import { BlocklistToken } from "../mocks/BlocklistToken.sol";
import { ReentrantToken } from "../mocks/ReentrantToken.sol";

/// @notice Runs the full lifecycle suite with a 6-decimals ERC-20 (USDC-like), plus token edge cases:
///         fee-on-transfer, missing return values (USDT), blocklists (USDC), re-entrant hooks and donations.
contract EscrowErc20Test is EscrowLifecycleTests {
    function _deployToken() internal override returns (address) {
        return address(new MockERC20("Mock USD", "mUSD", 6));
    }

    function _amount() internal pure override returns (uint256) {
        return 1000e6; // 1,000 mUSD
    }

    /// @dev Creates an escrow denominated in `t` for the default parties.
    function _escrowFor(address t) internal returns (Escrow) {
        Escrow.EscrowParams memory p = _params();
        p.token = t;
        return _create(p);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/
    function testDeposit_revertsIfEthSent() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(Escrow.Escrow__UnexpectedEth.selector);
        escrow.deposit{ value: 1 ether }();
    }

    function testDeposit_revertsWithoutApproval() public {
        _fund(buyer, _amount());
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, _amount())
        );
        escrow.deposit();
    }

    function testDeposit_revertsWithInsufficientBalance() public {
        vm.startPrank(buyer);
        MockERC20(token).approve(address(escrow), _amount());
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, buyer, 0, _amount()));
        escrow.deposit();
        vm.stopPrank();
    }

    function testDeposit_rejectsFeeOnTransferToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        Escrow target = _escrowFor(address(fot));
        uint256 amount = _amount();
        fot.mint(buyer, amount);

        vm.startPrank(buyer);
        fot.approve(address(target), amount);
        vm.expectRevert(
            abi.encodeWithSelector(Escrow.Escrow__FeeOnTransferNotSupported.selector, amount - amount / 100, amount)
        );
        target.deposit();
        vm.stopPrank();

        // Nothing changed: the escrow is still waiting for a (valid) deposit.
        assertEq(uint256(target.s_state()), uint256(Escrow.State.AWAITING_DEPOSIT));
    }

    function testDonationBeforeDepositDoesNotBreakAccounting() public {
        // Someone sends tokens straight to the escrow before the buyer deposits.
        _fund(address(this), 7e6);
        assertTrue(MockERC20(token).transfer(address(escrow), 7e6));

        _deposit();
        vm.prank(buyer);
        escrow.confirmDelivery();
        vm.prank(seller);
        escrow.withdraw();
        vm.prank(feeRecipient);
        escrow.withdraw();

        // Accounting is driven by s_amount, not balanceOf: parties get exactly their share,
        // the donation simply stays in the contract.
        assertEq(_balance(seller), _sellerAmount());
        assertEq(_balance(feeRecipient), _fee());
        assertEq(_balance(address(escrow)), 7e6);
    }

    /*//////////////////////////////////////////////////////////////
                      NON-STANDARD TOKENS (USDT-LIKE)
    //////////////////////////////////////////////////////////////*/
    function testNoReturnToken_fullLifecycle() public {
        NoReturnToken usdt = new NoReturnToken();
        Escrow target = _escrowFor(address(usdt));
        usdt.mint(buyer, _amount());

        vm.startPrank(buyer);
        usdt.approve(address(target), _amount());
        target.deposit();
        target.confirmDelivery();
        vm.stopPrank();

        vm.prank(seller);
        target.withdraw();
        vm.prank(feeRecipient);
        target.withdraw();

        assertEq(usdt.balanceOf(seller), _sellerAmount());
        assertEq(usdt.balanceOf(feeRecipient), _fee());
        assertEq(usdt.balanceOf(address(target)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         BLOCKLISTS (USDC-LIKE)
    //////////////////////////////////////////////////////////////*/
    function testBlocklist_blockedSellerCanRedirectWithWithdrawTo() public {
        BlocklistToken usdc = new BlocklistToken();
        Escrow target = _escrowFor(address(usdc));
        usdc.mint(buyer, _amount());

        vm.startPrank(buyer);
        usdc.approve(address(target), _amount());
        target.deposit();
        target.confirmDelivery();
        vm.stopPrank();

        usdc.setBlocked(seller, true);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.BlocklistToken__Blocked.selector, seller));
        target.withdraw();

        // The fee recipient is not affected by the seller being blocked.
        vm.prank(feeRecipient);
        target.withdraw();
        assertEq(usdc.balanceOf(feeRecipient), _fee());

        // The seller rescues their funds to a clean address.
        address clean = makeAddr("clean");
        vm.prank(seller);
        target.withdrawTo(clean);
        assertEq(usdc.balanceOf(clean), _sellerAmount());
        assertEq(usdc.balanceOf(address(target)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                               REENTRANCY
    //////////////////////////////////////////////////////////////*/
    function testReentrantToken_cannotReenterDuringDeposit() public {
        ReentrantToken evil = new ReentrantToken();
        Escrow target = _escrowFor(address(evil));
        evil.mint(buyer, _amount());
        evil.setHook(address(target), abi.encodeCall(Escrow.withdraw, ()));

        vm.startPrank(buyer);
        evil.approve(address(target), _amount());
        target.deposit();
        vm.stopPrank();

        assertTrue(evil.hookAttempted());
        assertFalse(evil.hookSucceeded());
        assertEq(bytes4(evil.hookRevertData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(uint256(target.s_state()), uint256(Escrow.State.AWAITING_DELIVERY));
    }

    function testReentrantToken_cannotReenterDuringWithdraw() public {
        ReentrantToken evil = new ReentrantToken();
        Escrow target = _escrowFor(address(evil));
        evil.mint(buyer, _amount());

        vm.startPrank(buyer);
        evil.approve(address(target), _amount());
        target.deposit();
        target.confirmDelivery();
        vm.stopPrank();

        // Arm the hook only now, so it fires on the payout transfer.
        evil.setHook(address(target), abi.encodeCall(Escrow.withdraw, ()));
        vm.prank(seller);
        target.withdraw();

        assertFalse(evil.hookSucceeded());
        assertEq(bytes4(evil.hookRevertData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(evil.balanceOf(seller), _sellerAmount());
        assertEq(evil.balanceOf(address(target)), _fee());
    }
}
