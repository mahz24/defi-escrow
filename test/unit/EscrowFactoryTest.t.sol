// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Errors } from "@openzeppelin/contracts/utils/Errors.sol";
import { Escrow } from "../../src/Escrow.sol";
import { EscrowFactory } from "../../src/EscrowFactory.sol";
import { EscrowTestBase } from "../utils/EscrowTestBase.sol";

contract EscrowFactoryTest is EscrowTestBase {
    event EscrowCreated(
        address indexed escrow,
        address indexed buyer,
        address indexed seller,
        address arbiter,
        address token,
        uint256 amount,
        uint256 protocolFeeBps
    );
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    function _deployToken() internal pure override returns (address) {
        return address(0);
    }

    function _amount() internal pure override returns (uint256) {
        return 1 ether;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    function testConstructor_setsConfig() public view {
        assertEq(factory.owner(), factoryOwner);
        assertEq(factory.s_feeRecipient(), feeRecipient);
        assertEq(factory.s_protocolFeeBps(), FEE_BPS);
        assertGt(factory.i_implementation().code.length, 0);
    }

    function testConstructor_revertsIfOwnerIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new EscrowFactory(address(0), feeRecipient, FEE_BPS);
    }

    function testConstructor_revertsIfFeeRecipientIsZero() public {
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidFeeRecipient.selector);
        new EscrowFactory(factoryOwner, address(0), FEE_BPS);
    }

    function testConstructor_revertsIfFeeAboveCap() public {
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidProtocolFee.selector);
        new EscrowFactory(factoryOwner, feeRecipient, 501);
    }

    /*//////////////////////////////////////////////////////////////
                             CREATE ESCROW
    //////////////////////////////////////////////////////////////*/
    function testCreateEscrow_deploysToPredictedAddress() public {
        bytes32 salt = keccak256("order-42");
        address predicted = factory.predictEscrowAddress(buyer, salt);
        assertEq(predicted.code.length, 0);

        vm.prank(buyer);
        address created = factory.createEscrow(_params(), salt);

        assertEq(created, predicted);
        assertTrue(factory.s_isEscrow(created));
    }

    function testCreateEscrow_isMinimalProxyClone() public view {
        // EIP-1167 runtime bytecode is 45 bytes, versus kilobytes for a full Escrow deployment.
        assertEq(address(escrow).code.length, 45);
        assertGt(factory.i_implementation().code.length, 5000);
    }

    function testCreateEscrow_isMuchCheaperThanFullDeployment() public {
        uint256 gasBefore = gasleft();
        new Escrow();
        uint256 fullDeployGas = gasBefore - gasleft();

        gasBefore = gasleft();
        factory.createEscrow(_params(), keccak256("gas"));
        uint256 cloneGas = gasBefore - gasleft();

        // Clone + initialize + indexing costs well under half of deploying the logic contract.
        assertLt(cloneGas * 2, fullDeployGas);
    }

    function testCreateEscrow_initializesWithFactoryFee() public view {
        assertEq(escrow.s_feeRecipient(), feeRecipient);
        assertEq(escrow.s_protocolFeeBps(), FEE_BPS);
        assertEq(escrow.s_buyer(), buyer);
    }

    function testCreateEscrow_emitsEscrowCreated() public {
        bytes32 salt = keccak256("event");
        address predicted = factory.predictEscrowAddress(address(this), salt);

        vm.expectEmit(true, true, true, true, address(factory));
        emit EscrowCreated(predicted, buyer, seller, arbiter, address(0), _amount(), FEE_BPS);
        factory.createEscrow(_params(), salt);
    }

    function testCreateEscrow_sameCreatorSameSaltReverts() public {
        bytes32 salt = keccak256("dup");
        factory.createEscrow(_params(), salt);

        vm.expectRevert(Errors.FailedDeployment.selector);
        factory.createEscrow(_params(), salt);
    }

    function testCreateEscrow_saltIsBoundToCreator() public {
        // Nobody can squat another creator's predicted address by reusing their salt.
        bytes32 salt = keccak256("shared");
        vm.prank(buyer);
        address a = factory.createEscrow(_params(), salt);
        vm.prank(seller);
        address b = factory.createEscrow(_params(), salt);

        assertTrue(a != b);
        assertEq(a, factory.predictEscrowAddress(buyer, salt));
        assertEq(b, factory.predictEscrowAddress(seller, salt));
    }

    function testCreateEscrow_revertsOnInvalidParams() public {
        Escrow.EscrowParams memory p = _params();
        p.amount = 0;
        vm.expectRevert(Escrow.Escrow__InvalidExpectedAmount.selector);
        factory.createEscrow(p, keccak256("bad"));
        assertEq(factory.getEscrowCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                                INDEXING
    //////////////////////////////////////////////////////////////*/
    function testIndexing_tracksAllEscrowsAndParticipants() public {
        address otherSeller = makeAddr("otherSeller");
        Escrow.EscrowParams memory p = _params();
        p.seller = otherSeller;
        Escrow second = _create(p);

        assertEq(factory.getEscrowCount(), 2);
        address[] memory all = factory.getEscrows(0, 10);
        assertEq(all.length, 2);
        assertEq(all[0], address(escrow));
        assertEq(all[1], address(second));

        assertEq(factory.getEscrowCountByParticipant(buyer), 2);
        assertEq(factory.getEscrowCountByParticipant(arbiter), 2);
        assertEq(factory.getEscrowCountByParticipant(seller), 1);
        assertEq(factory.getEscrowCountByParticipant(otherSeller), 1);
        assertEq(factory.getEscrowsByParticipant(otherSeller, 0, 10)[0], address(second));
        assertEq(factory.getEscrowCountByParticipant(feeRecipient), 0);
    }

    function testPagination_returnsRequestedSlice() public {
        for (uint256 i; i < 4; ++i) {
            _create(_params());
        }
        // 5 escrows in total (1 from setUp).
        address[] memory page = factory.getEscrows(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], factory.getEscrows(1, 1)[0]);

        assertEq(factory.getEscrows(3, 100).length, 2); // clamps to the end
        assertEq(factory.getEscrows(5, 1).length, 0); // offset past the end
        assertEq(factory.getEscrows(0, type(uint256).max).length, 5); // no overflow on huge limits
        assertEq(factory.getEscrowsByParticipant(buyer, 4, 10).length, 1);
    }

    /*//////////////////////////////////////////////////////////////
                             FEE SETTINGS
    //////////////////////////////////////////////////////////////*/
    function testSetProtocolFee_onlyAffectsNewEscrows() public {
        vm.expectEmit(false, false, false, true, address(factory));
        emit ProtocolFeeUpdated(FEE_BPS, 250);
        vm.prank(factoryOwner);
        factory.setProtocolFee(250);

        Escrow newer = _create(_params());
        assertEq(newer.s_protocolFeeBps(), 250);
        assertEq(escrow.s_protocolFeeBps(), FEE_BPS); // existing trade keeps its terms
    }

    function testSetProtocolFee_revertsAboveCap() public {
        vm.prank(factoryOwner);
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidProtocolFee.selector);
        factory.setProtocolFee(501);
    }

    function testSetProtocolFee_onlyOwner() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        factory.setProtocolFee(0);
    }

    function testSetFeeRecipient_onlyAffectsNewEscrows() public {
        address treasury = makeAddr("treasury");
        vm.expectEmit(true, true, false, false, address(factory));
        emit FeeRecipientUpdated(feeRecipient, treasury);
        vm.prank(factoryOwner);
        factory.setFeeRecipient(treasury);

        assertEq(_create(_params()).s_feeRecipient(), treasury);
        assertEq(escrow.s_feeRecipient(), feeRecipient);
    }

    function testSetFeeRecipient_revertsIfZero() public {
        vm.prank(factoryOwner);
        vm.expectRevert(EscrowFactory.EscrowFactory__InvalidFeeRecipient.selector);
        factory.setFeeRecipient(address(0));
    }

    function testSetFeeRecipient_onlyOwner() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, seller));
        factory.setFeeRecipient(seller);
    }

    /*//////////////////////////////////////////////////////////////
                               OWNERSHIP
    //////////////////////////////////////////////////////////////*/
    function testOwnership_isTwoStep() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(factoryOwner);
        factory.transferOwnership(newOwner);

        // Nothing changes until the new owner accepts.
        assertEq(factory.owner(), factoryOwner);
        assertEq(factory.pendingOwner(), newOwner);

        vm.prank(newOwner);
        factory.acceptOwnership();
        assertEq(factory.owner(), newOwner);

        vm.prank(newOwner);
        factory.setProtocolFee(0);
        assertEq(factory.s_protocolFeeBps(), 0);
    }
}
