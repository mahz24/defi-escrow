// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { Escrow } from "../../src/Escrow.sol";
import { EscrowTestBase } from "../utils/EscrowTestBase.sol";

/// @notice Initialization rules for escrow clones: parameter validation and one-shot initialization.
contract EscrowInitializeTest is EscrowTestBase {
    function _deployToken() internal pure override returns (address) {
        return address(0);
    }

    function _amount() internal pure override returns (uint256) {
        return 1 ether;
    }

    function _expectCreateRevert(Escrow.EscrowParams memory p, bytes4 selector) internal {
        vm.expectRevert(selector);
        factory.createEscrow(p, keccak256("revert"));
    }

    /*//////////////////////////////////////////////////////////////
                          ONE-SHOT INITIALIZATION
    //////////////////////////////////////////////////////////////*/
    function testImplementationCannotBeInitialized() public {
        Escrow implementation = Escrow(factory.i_implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(_params(), feeRecipient, FEE_BPS);
    }

    function testCloneCannotBeReinitialized() public {
        Escrow.EscrowParams memory hijack = _params();
        hijack.seller = makeAddr("attacker");

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.initialize(hijack, makeAddr("attacker"), FEE_BPS);
        assertEq(escrow.s_seller(), seller);
    }

    /*//////////////////////////////////////////////////////////////
                          PARAMETER VALIDATION
    //////////////////////////////////////////////////////////////*/
    function testInit_revertsIfBuyerIsZero() public {
        Escrow.EscrowParams memory p = _params();
        p.buyer = address(0);
        _expectCreateRevert(p, Escrow.Escrow__InvalidAddress.selector);
    }

    function testInit_revertsIfSellerIsZero() public {
        Escrow.EscrowParams memory p = _params();
        p.seller = address(0);
        _expectCreateRevert(p, Escrow.Escrow__InvalidAddress.selector);
    }

    function testInit_revertsIfArbiterIsZero() public {
        Escrow.EscrowParams memory p = _params();
        p.arbiter = address(0);
        _expectCreateRevert(p, Escrow.Escrow__InvalidAddress.selector);
    }

    function testInit_revertsIfBuyerIsSeller() public {
        Escrow.EscrowParams memory p = _params();
        p.seller = buyer;
        _expectCreateRevert(p, Escrow.Escrow__SameSellerAndBuyer.selector);
    }

    function testInit_revertsIfBuyerIsArbiter() public {
        Escrow.EscrowParams memory p = _params();
        p.arbiter = buyer;
        _expectCreateRevert(p, Escrow.Escrow__SameBuyerAndArbiter.selector);
    }

    function testInit_revertsIfSellerIsArbiter() public {
        Escrow.EscrowParams memory p = _params();
        p.arbiter = seller;
        _expectCreateRevert(p, Escrow.Escrow__SameSellerAndArbiter.selector);
    }

    function testInit_revertsIfTokenIsNotAContract() public {
        Escrow.EscrowParams memory p = _params();
        p.token = makeAddr("eoaToken");
        _expectCreateRevert(p, Escrow.Escrow__InvalidToken.selector);
    }

    function testInit_revertsIfAmountIsZero() public {
        Escrow.EscrowParams memory p = _params();
        p.amount = 0;
        _expectCreateRevert(p, Escrow.Escrow__InvalidExpectedAmount.selector);
    }

    function testInit_revertsIfDepositWindowIsZero() public {
        Escrow.EscrowParams memory p = _params();
        p.depositWindow = 0;
        _expectCreateRevert(p, Escrow.Escrow__InvalidDepositWindow.selector);
    }

    function testInit_revertsIfDeliveryWindowIsZero() public {
        Escrow.EscrowParams memory p = _params();
        p.deliveryWindow = 0;
        _expectCreateRevert(p, Escrow.Escrow__InvalidDeliveryWindow.selector);
    }

    function testInit_revertsIfDisputeWindowIsZero() public {
        Escrow.EscrowParams memory p = _params();
        p.disputeWindow = 0;
        _expectCreateRevert(p, Escrow.Escrow__InvalidDisputeWindow.selector);
    }

    function testInit_revertsIfWindowsOverflowUint32() public {
        uint256 tooLong = uint256(type(uint32).max) + 1;
        Escrow.EscrowParams memory p = _params();

        p.depositWindow = tooLong;
        _expectCreateRevert(p, Escrow.Escrow__InvalidDepositWindow.selector);
        p.depositWindow = DEPOSIT_WINDOW;

        p.deliveryWindow = tooLong;
        _expectCreateRevert(p, Escrow.Escrow__InvalidDeliveryWindow.selector);
        p.deliveryWindow = DELIVERY_WINDOW;

        p.disputeWindow = tooLong;
        _expectCreateRevert(p, Escrow.Escrow__InvalidDisputeWindow.selector);
    }

    function testInit_acceptsMaxUint32Windows() public {
        Escrow.EscrowParams memory p = _params();
        p.depositWindow = type(uint32).max;
        p.deliveryWindow = type(uint32).max;
        p.disputeWindow = type(uint32).max;
        Escrow e = _create(p);
        assertEq(e.s_deliveryWindow(), type(uint32).max);
        assertEq(e.s_depositDeadline(), block.timestamp + type(uint32).max);
    }

    /// @dev The factory never passes these, but the escrow validates them on its own (defense in depth),
    ///      e.g. for clones created outside the factory.
    function testInit_revertsIfFeeRecipientIsZero() public {
        Escrow clone = Escrow(Clones.clone(factory.i_implementation()));
        vm.expectRevert(Escrow.Escrow__InvalidAddress.selector);
        clone.initialize(_params(), address(0), FEE_BPS);
    }

    function testInit_revertsIfFeeAboveCap() public {
        Escrow clone = Escrow(Clones.clone(factory.i_implementation()));
        uint256 maxFee = clone.MAX_PROTOCOL_FEE_BPS();
        vm.expectRevert(Escrow.Escrow__InvalidProtocolFee.selector);
        clone.initialize(_params(), feeRecipient, maxFee + 1);
    }

    function testInit_acceptsFeeAtCapAndZeroFee() public {
        Escrow atCap = Escrow(Clones.clone(factory.i_implementation()));
        atCap.initialize(_params(), feeRecipient, 500);
        assertEq(atCap.getProtocolFee(), _amount() * 500 / BPS_DIVISOR);

        Escrow free = Escrow(Clones.clone(factory.i_implementation()));
        free.initialize(_params(), feeRecipient, 0);
        assertEq(free.getProtocolFee(), 0);
        assertEq(free.getSellerPayout(), _amount());
    }

    function testInit_feeRecipientMayBeAParty() public {
        // Allowed: e.g. a marketplace that both arbitrates and collects the fee.
        Escrow clone = Escrow(Clones.clone(factory.i_implementation()));
        clone.initialize(_params(), arbiter, FEE_BPS);
        assertEq(clone.s_feeRecipient(), arbiter);
    }
}
