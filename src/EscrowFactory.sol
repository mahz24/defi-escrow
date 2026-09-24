// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Escrow, MAX_FEE_BPS } from "./Escrow.sol";

/// @title EscrowFactory
/// @author mahz24
/// @notice Deploys one cheap EIP-1167 clone of `Escrow` per trade and indexes every escrow by participant.
/// @dev - Clones are created with CREATE2 and a salt bound to `msg.sender`, so addresses are predictable
///        before creation (useful for sharing/pre-approving) and nobody can squat another creator's address.
///      - The protocol fee and fee recipient are owned by the factory and snapshotted into each escrow at
///        creation: changing them never affects existing trades.
///      - Ownership uses a two-step transfer to avoid handing the protocol to a mistyped address.
contract EscrowFactory is Ownable2Step {
    using Clones for address;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error EscrowFactory__InvalidFeeRecipient();
    error EscrowFactory__InvalidProtocolFee();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice The `Escrow` logic contract every clone delegates to.
    address public immutable i_implementation;

    address public s_feeRecipient;
    uint256 public s_protocolFeeBps;

    address[] private s_escrows;
    mapping(address participant => address[] escrows) private s_escrowsByParticipant;
    mapping(address escrow => bool) public s_isEscrow;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
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

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /// @param initialOwner Account allowed to update the fee settings.
    /// @param feeRecipient Account that receives protocol fees from new escrows.
    /// @param protocolFeeBps Fee applied to new escrows, in basis points (max 500).
    constructor(address initialOwner, address feeRecipient, uint256 protocolFeeBps) Ownable(initialOwner) {
        _setFeeRecipient(feeRecipient);
        _setProtocolFee(protocolFeeBps);
        i_implementation = address(new Escrow());
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Deploys and initializes a new escrow clone in a single transaction.
    /// @param params Trade terms (buyer, seller, arbiter, token, amount, windows).
    /// @param salt Any value chosen by the creator; combined with `msg.sender` to derive the address.
    /// @return escrow Address of the new escrow (equals `predictEscrowAddress(msg.sender, salt)`).
    function createEscrow(Escrow.EscrowParams calldata params, bytes32 salt) external returns (address escrow) {
        uint256 feeBps = s_protocolFeeBps;
        escrow = i_implementation.cloneDeterministic(_creatorSalt(msg.sender, salt));

        // Effects before the (trusted) initialize call; if it reverts, the whole creation reverts atomically.
        s_isEscrow[escrow] = true;
        s_escrows.push(escrow);
        s_escrowsByParticipant[params.buyer].push(escrow);
        s_escrowsByParticipant[params.seller].push(escrow);
        s_escrowsByParticipant[params.arbiter].push(escrow);
        emit EscrowCreated(escrow, params.buyer, params.seller, params.arbiter, params.token, params.amount, feeBps);

        Escrow(escrow).initialize(params, s_feeRecipient, feeBps);
    }

    /// @notice Updates the fee for escrows created from now on. Existing escrows keep their fee.
    function setProtocolFee(uint256 newFeeBps) external onlyOwner {
        _setProtocolFee(newFeeBps);
    }

    /// @notice Updates the fee recipient for escrows created from now on.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        _setFeeRecipient(newRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Address `createEscrow` will deploy to for a given creator and salt.
    function predictEscrowAddress(address creator, bytes32 salt) external view returns (address) {
        return i_implementation.predictDeterministicAddress(_creatorSalt(creator, salt));
    }

    function getEscrowCount() external view returns (uint256) {
        return s_escrows.length;
    }

    /// @notice Paginated list of every escrow created by this factory, oldest first.
    function getEscrows(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        return _slice(s_escrows, offset, limit);
    }

    /// @notice Number of escrows where `participant` is buyer, seller or arbiter.
    function getEscrowCountByParticipant(address participant) external view returns (uint256) {
        return s_escrowsByParticipant[participant].length;
    }

    /// @notice Paginated history of escrows where `participant` is buyer, seller or arbiter.
    function getEscrowsByParticipant(address participant, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        return _slice(s_escrowsByParticipant[participant], offset, limit);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _setProtocolFee(uint256 newFeeBps) internal {
        if (newFeeBps > MAX_FEE_BPS) revert EscrowFactory__InvalidProtocolFee();
        emit ProtocolFeeUpdated(s_protocolFeeBps, newFeeBps);
        s_protocolFeeBps = newFeeBps;
    }

    function _setFeeRecipient(address newRecipient) internal {
        if (newRecipient == address(0)) revert EscrowFactory__InvalidFeeRecipient();
        emit FeeRecipientUpdated(s_feeRecipient, newRecipient);
        s_feeRecipient = newRecipient;
    }

    function _creatorSalt(address creator, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }

    function _slice(address[] storage list, uint256 offset, uint256 limit)
        internal
        view
        returns (address[] memory page)
    {
        uint256 length = list.length;
        if (offset >= length) return new address[](0);
        uint256 end = limit > length - offset ? length : offset + limit; // overflow-safe for any limit
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = list[i];
        }
    }
}
