# [MEDIUM] LiquidationEngine same-tx multi-call defeats per-call close factor for deeply-underwater positions

## Target
`src/core/liquidation/LiquidationEngine.sol:107-189` (the `liquidate` function, specifically the close-factor cap at lines 132-135). Doc claim at `LiquidationEngineStorage.sol:25-27`.

## Summary
`liquidate` enforces `closeFactor` per call but is callable repeatedly within the same transaction. For a position deeply underwater (HF stays < 1 after each partial seize, which is typical when the bonus extraction widens the underwater gap), an attacker chains N calls and extracts `1 - (1 - cf)^N` of the original debt — well above the per-call ceiling.

The protocol's `LiquidationEngineStorage.sol:25-27` docstring describes the close factor as "to avoid over-liquidating a merely-unhealthy position." Multi-call defeats that stated intent for the underwater case.

## Detail
- **Lines:** 107-189 (`liquidate`); close-factor cap at 132-135; HF trigger at 128.
- **Category:** Liquidation throttle bypass.
- **Root cause:** The cap is enforced relative to the *current* debt read in this call (`_borrowDebt[marketId][borrower]`). After a partial liquidation:
  - Collateral seized = `repaid * (1+bonus)` USD. Debt reduced = `repaid`.
  - The bonus chunk leaves the position MORE underwater (collateralUsd - debtUsd shrinks faster than collateralUsd alone).
  - For HF<<1 positions, the second call sees a smaller debt and still passes `isLiquidatable` (HF still < 1).
  - N chained calls extract progressively, reaching collateral exhaustion in O(log) calls.

`nonReentrant` blocks intra-call recursion, but not separate top-level calls in the same tx. Aave V3 has the same behavior; Centuari's docstring frames the cap more strictly than Aave does, creating a gap between stated intent and implementation.

## Impact
- **Borrower-side:** the borrower pays bonus on a larger fraction of their debt than the docstring implies. For cf=50%, bonus=8%:
  - Single call ceiling: 50% repaid, 54% seized → 4% bonus over what's "owed".
  - 2-call chain: 75% repaid, 81% seized → 6% bonus.
  - 3-call chain: 87.5% repaid, 94.5% seized → 7% bonus.
- **Protocol-side:** no direct loss; over-liquidation reduces bad debt faster (arguably a positive). The harm is borrower-borne.

For a merely-unhealthy position (HF just below 1), the first call typically lifts HF above 1, and the second call's `isLiquidatable` check fails — the cap self-honors. So this finding is specifically about the deeply-underwater regime.

## Recommended Fix
Two complementary options:

**Option A — Relax the docstring** to acknowledge Aave-equivalent multi-call behavior:
```solidity
/// @notice Max fraction of a market's debt repayable per HF-triggered liquidation
///         CALL. Multi-call within one transaction is permitted; deeply-underwater
///         positions may be fully liquidated in O(log(1/(1-cf))) calls.
```

**Option B — Per-block / per-position cooldown** (true enforcement of the original docstring intent):
```solidity
mapping(address => mapping(bytes32 => uint256)) internal _lastLiquidatedBlock;

function liquidate(...) ... {
    if (_lastLiquidatedBlock[borrower][marketId] == block.number) revert LiquidationCooldown();
    _lastLiquidatedBlock[borrower][marketId] = block.number;
    ...
}
```
A new storage slot is required; budget against the existing `__gap`.

If Centuari deliberately wants Aave-style behavior, Option A is sufficient. If the docstring is load-bearing for product / regulatory commitments, Option B enforces it.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Medium |
| `confidence_0_100` | 78 |
| `single_strongest_reject` | "Industry-standard Aave V3 has the same per-call behavior; not a bug." — counter: the protocol's own docstring frames the cap more strictly than Aave's; the implementation should match the stated intent or the docstring should be relaxed. |
| `gate_failures` | none |
| `poc_status` | NOT_BUILT (math derivation supports the claim; PoC straightforward) |
