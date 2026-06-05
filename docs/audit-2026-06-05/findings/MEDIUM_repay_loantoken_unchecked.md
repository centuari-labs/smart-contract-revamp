# [MEDIUM] `Centuari.repay` and `Centuari.liquidationRepay` accept arbitrary `loanToken` parameter

## Target
`src/core/centuari/Centuari.sol:243-274` (`repay`), `:284-311` (`liquidationRepay`).

## Summary
Both functions take `loanToken` as a caller-controlled parameter and use it to debit the `borrower` / `liquidator` BalanceLedger balance, while the *debt* itself is keyed by the separate `marketId` parameter. No check ties `loanToken` to `_marketLoanToken[marketId]`. An operator (`repay`) or liquidation engine (`liquidationRepay`) that passes a mismatched `loanToken` zeroes out the borrower's debt while debiting an entirely different token from the payer.

## Detail
- **Lines:** 243-274 (`repay`, debit at line 268), 284-311 (`liquidationRepay`, debit at line 308).
- **Category:** Defensive cross-parameter check missing.

```solidity
// repay (Centuari.sol:243-274)
function repay(bytes32 marketId, address borrower, address loanToken, uint256 amount)
    external onlyOperator whenNotPaused nonReentrant
{
    ...
    _borrowDebt[marketId][borrower] = debt - repayAmount;
    if (debt - repayAmount == 0) _borrowerMarkets[borrower].remove(marketId);
    IBalanceLedger(_balanceLedger).debit(borrower, loanToken, repayAmount);  // <-- loanToken used here
    ...
}
```

The function pairs are:
- (`marketId`, `_borrowDebt[marketId][borrower]`) — debt accounting.
- (`loanToken`, `BalanceLedger.debit(...)`) — balance debit.

These are independent values. There is no `if (loanToken != _marketLoanToken[marketId]) revert InvalidAmount();` guard.

## Why this is Medium and not High
Both functions are role-gated (`onlyOperator`, `onlyLiquidationEngine`). The current `LiquidationEngine` derives `marketId` from `(loanToken, maturity)` internally and passes both consistently, so the engine-callable path is safe today. The operator-callable `repay` is the practical concern: an operator typo or compromised key can zero debt by debiting the wrong token.

This is a defensive check that costs one storage read per call and turns a class of silent accounting drift into a hard revert.

## Impact
- **Operator typo / bug:** operator calls `repay(mid_USDC_T1, borrower, DAI, 100)`. Borrower's USDC debt at the canonical USDC market is zeroed; their DAI balance is debited 100. The lender of that USDC position still expects USDC at maturity, but the protocol has no record of the debt and no offsetting repayment — bad debt enters the system silently.
- **Future liquidation engine variants:** a new `_liquidationEngine` could be added later that does not derive `marketId` strictly from `(loanToken, maturity)`. Without the check at the Centuari layer, the consistency is enforced only at the call-site, not by the contract.

## Recommended Fix
```solidity
// In repay (after the debt == 0 check at line 254):
if (loanToken != _marketLoanToken[marketId]) revert InvalidAmount();

// In liquidationRepay (after the debt == 0 check at line 294):
if (loanToken != _marketLoanToken[marketId]) revert InvalidAmount();
```

(A new dedicated `LoanTokenMismatch` error would be even clearer.)

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Medium |
| `confidence_0_100` | 90 |
| `single_strongest_reject` | "Both callers are trusted." — counter: defense-in-depth on operator-trusted paths is a project norm (e.g., M2 fix on `seedBorrowerMarkets` introduced exactly this kind of check). |
| `gate_failures` | none |
| `poc_status` | NOT_BUILT (defensive check; no exploit since callers are trusted) |
