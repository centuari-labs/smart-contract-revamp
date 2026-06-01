// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRiskModule} from "../../src/interfaces/IRiskModule.sol";

/// @title MockRiskModule
/// @notice Configurable test double for `IRiskModule`. Permissive by default
///         (`canUnflag`/`canWithdraw` true, never liquidatable, max HF); flip any
///         decision with the setters to drive deny paths. Stands in for the real
///         `RiskModule` in unit tests, so suites that need a fail-closed gate
///         configure this mock explicitly instead of standing up the oracle stack.
contract MockRiskModule is IRiskModule {
    bool public canUnflagResult = true;
    bool public canWithdrawResult = true;
    bool public isLiquidatableResult = false;
    uint256 public healthFactorResult = type(uint256).max;

    function setCanUnflag(bool value) external {
        canUnflagResult = value;
    }

    function setCanWithdraw(bool value) external {
        canWithdrawResult = value;
    }

    function setIsLiquidatable(bool value) external {
        isLiquidatableResult = value;
    }

    function setHealthFactor(uint256 value) external {
        healthFactorResult = value;
    }

    /// @inheritdoc IRiskModule
    function canUnflag(address, address) external view returns (bool) {
        return canUnflagResult;
    }

    /// @inheritdoc IRiskModule
    function canWithdraw(address, address, uint256) external view returns (bool) {
        return canWithdrawResult;
    }

    /// @inheritdoc IRiskModule
    function healthFactor(address) external view returns (uint256) {
        return healthFactorResult;
    }

    /// @inheritdoc IRiskModule
    function isLiquidatable(address) external view returns (bool) {
        return isLiquidatableResult;
    }
}
