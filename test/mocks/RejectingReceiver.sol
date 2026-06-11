// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/// @notice Mock used to test withdrawal failure path in Escrow.
/// Reverts on any incoming ETH transfer.
contract RejectingReceiver {
    receive() external payable {
        revert();
    }
}
