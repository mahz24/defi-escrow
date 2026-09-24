// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Malicious token with a transfer hook (think ERC-777) that calls back into a target contract
///         in the middle of a transfer. Records whether the re-entrant call succeeded.
contract ReentrantToken is ERC20 {
    address public hookTarget;
    bytes public hookData;
    bool public hookAttempted;
    bool public hookSucceeded;
    bytes public hookRevertData;

    constructor() ERC20("Reentrant", "RE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hookTarget != address(0) && !hookAttempted && from != address(0)) {
            hookAttempted = true;
            (hookSucceeded, hookRevertData) = hookTarget.call(hookData);
        }
    }
}
