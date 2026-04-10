// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRiskModule} from "../../interfaces/IRiskModule.sol";
import {IBalanceLedger} from "../../interfaces/IBalanceLedger.sol";

/// @title RiskModuleStub
/// @notice Conservative, Centuari-independent Phase 1 implementation of
///         `IRiskModule`.
/// @dev Centuari exposes debt only at the per-market granularity
///      (`_borrowDebt[marketId][borrower]`) and has no per-user debt
///      aggregator, so a stub that reads Centuari cheaply is not possible
///      without adding new storage on Centuari — out of scope for P1a.
///
///      Instead the stub takes the strictest possible fail-closed position:
///      - `canUnflag` always returns false. The only Phase 1 path to clear a
///        flag while holding any collateral is the auto-unflag loop inside
///        `Centuari.repay()` when debt reaches zero (landed in P1b). App-user
///        mid-life unflagging via `CollateralManager.unflagFor` is blocked.
///      - `canWithdraw` returns true only if the asset is NOT flagged.
///        Flagged assets cannot be withdrawn regardless of debt state. The
///        caller (`WithdrawalRegistry`) surfaces `WithdrawalBlockedByHF` on a
///        false return.
///
///      Phase 2 swap path: governance calls
///      `CollateralManager.setRiskModule(realRiskModule)` — no code changes in
///      any caller contract, the policy upgrade flips on instantly.
contract RiskModuleStub is IRiskModule {
    /// @notice The BalanceLedger whose collateral flag is consulted
    IBalanceLedger public immutable balanceLedger;

    /// @notice Thrown when the BalanceLedger address is zero
    error ZeroAddress();

    /// @param balanceLedger_ The BalanceLedger whose flags this stub reads
    constructor(address balanceLedger_) {
        if (balanceLedger_ == address(0)) revert ZeroAddress();
        balanceLedger = IBalanceLedger(balanceLedger_);
    }

    /// @inheritdoc IRiskModule
    /// @dev Always returns false in Phase 1.
    function canUnflag(address, address) external pure returns (bool) {
        return false;
    }

    /// @inheritdoc IRiskModule
    /// @dev Returns true iff the asset is not currently flagged as collateral.
    ///      The `amount` argument is ignored by the stub but kept in the
    ///      interface so Phase 2 HF math can size-check withdrawals.
    function canWithdraw(
        address user,
        address asset,
        uint256 /* amount */
    ) external view returns (bool) {
        return !balanceLedger.usedAsCollateral(user, asset);
    }
}
