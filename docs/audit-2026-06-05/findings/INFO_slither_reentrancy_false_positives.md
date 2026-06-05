# [INFO] Slither-flagged reentrancy in `settleMatch` and `withdrawLendPosition` — verified safe

## Target
`src/core/centuari/Centuari.sol:102-193` (`settleMatch`), `:329-357` (`withdrawLendPosition`).

## Summary
Slither's `reentrancy-no-eth` and `reentrancy-benign` detectors flagged external calls preceding state writes inside both functions:
- `settleMatch` calls `CentuariBondERC20Factory.getOrCreate` before updating `_marketTotalCbt`, `_lendPositionCbtAmount`, and `_borrowDebt`.
- `withdrawLendPosition` calls `CentuariBondERC20.burn` before decrementing `_lendPositionCbtAmount` and `_marketTotalCbt`.

Both are guarded by `nonReentrant` on the entry function. The external call targets are:
- `getOrCreate`: owner-controlled factory, marked `onlyCentuari`, deploys a new `CentuariBondERC20` via CREATE2. The new contract's constructor does not call out.
- `burn`: standard OpenZeppelin ERC20 internal burn, no callbacks (no ERC777 hooks).

The flagged paths are safe under the current dependencies. The risk vector would activate only if (a) governance swapped the factory to a malicious one, or (b) the bond token is replaced by an ERC777-style token with `_beforeTokenTransfer` callbacks. Neither is reachable today; both would require an explicit governance change beyond the contract scope.

## Recommended Action
None for correctness. If future-proofing is desired, move the external call to the end of the function (full checks-effects-interactions) — but the `bondToken` address is needed earlier for the mint, so a refactor is non-trivial. Recommend simply documenting that the `bondToken` swap requires re-audit of the call ordering.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Informational |
| `confidence_0_100` | 100 |
| `gate_failures` | none |
