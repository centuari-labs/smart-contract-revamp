# [INFO] `_marketLoanToken[marketId]` set-once-then-stable trusts the operator on first settlement

## Target
`src/core/centuari/Centuari.sol:127-129`, `:589-613` (`seedBorrowerMarkets`).

## Summary
`settleMatch` writes `_marketLoanToken[marketId] = loanToken` only if the slot is currently zero. The first settlement with marketId X "wins" — subsequent settlements at the same X with a different `loanToken` argument leave the stored value unchanged. The function does NOT validate that `marketId == keccak256(loanToken, maturity)`.

`seedBorrowerMarkets` unconditionally overwrites `_marketLoanToken[mid] = loanTokens[i]` (line 609). For canonical `mid = keccak256(loanToken, maturity)` this is benign (collision-resistant). For operator-supplied non-canonical marketIds, this could in theory diverge from the original settlement's loanToken — but only if the operator does so deliberately.

Listed for completeness; the operator-trust boundary documented at INVARIANTS C-2 and ARCHITECTURE "Notable design choices #2" makes this not a security finding under the current threat model.

## Recommended Action
Defense-in-depth: derive `marketId` locally from `(loanToken, maturity)` in both `settleMatch` and `seedBorrowerMarkets`, OR add an explicit `marketId == keccak256(loanToken, maturity)` assert at function entry. This eliminates the operator's ability to create non-canonical accounting in the first place and converts a class of operator typos into hard reverts.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Informational |
| `confidence_0_100` | 100 |
| `gate_failures` | none |
