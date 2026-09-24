// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Escrow } from "../../src/Escrow.sol";

/// @notice Malicious seller that tries to re-enter `withdraw()` from its `receive()` hook.
/// @dev The re-entrant call is wrapped in try/catch so the outer withdrawal succeeds and the
///      test can assert the attacker was paid exactly once.
contract ReentrantReceiver {
    Escrow public target;
    uint256 public reentryAttempts;
    bool public reentrySucceeded;

    function setTarget(Escrow _target) external {
        target = _target;
    }

    function attack() external {
        target.withdraw();
    }

    receive() external payable {
        if (reentryAttempts == 0) {
            reentryAttempts++;
            try target.withdraw() {
                reentrySucceeded = true;
            } catch { }
        }
    }
}
