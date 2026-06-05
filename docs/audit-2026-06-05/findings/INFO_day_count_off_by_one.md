# [INFO] `_interestWithDayCount` always deducts one day from the loan tenor

## Target
`src/core/centuari/Centuari.sol:365-373`.

## Summary
The day-count formula computes `days_ = max(0, floor((maturity - start) / 1 days) - 1)`. So:
- A 1-day loan earns 0 interest.
- A 2-day loan earns 1 day's interest.
- A 30-day loan earns 29 days' interest.

This is documented at line 359 ("start+1 = day 1, maturity-1 = last day") and matches the off-chain `PortfolioService` math. Not a bug; flagged because the convention is unusual and the bond-token name (e.g., "CBT USDC 1 Jan 2025") may give users a misleading impression that the bond starts accruing on the start date.

## Recommended Action
Either (a) keep as-is and ensure the frontend / docs explain the convention, or (b) switch to a settled-day-count convention `days_ = rawDays` and update off-chain `PortfolioService` to match.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Informational |
| `confidence_0_100` | 100 |
| `gate_failures` | none |
| `poc_status` | N/A |
