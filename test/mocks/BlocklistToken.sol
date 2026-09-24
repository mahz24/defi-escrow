// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice USDC-style token whose admin can block addresses from receiving tokens.
contract BlocklistToken is ERC20 {
    error BlocklistToken__Blocked(address account);

    mapping(address => bool) public blocked;

    constructor() ERC20("Blocklist USD", "BUSD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[to]) revert BlocklistToken__Blocked(to);
        super._update(from, to, value);
    }
}
