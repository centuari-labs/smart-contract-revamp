---
name: RiskModule + LiquidationEngine Deep Audit (2026-04-01)
description: Mainnet-grade security audit of RiskModule.sol + LiquidationEngine.sol. 1 CRITICAL (_normalizeToUSD18 assumes $1/token), 2 HIGH (isPriceFresh no answer check, grace period key bypass), 4 MEDIUM, 4 LOW. VERDICT: REQUEST CHANGES.
type: project
---

## Audit: RiskModule + LiquidationEngine (2026-04-01)

### Scope
- RiskModule.sol, RiskModuleStorage.sol
- LiquidationEngine.sol, LiquidationEngineStorage.sol
- IRiskModule.sol, ILiquidationEngine.sol

### Key Findings

**CRITICAL (1):**
- C-01: `_normalizeToUSD18()` in both contracts does decimal shifting only (10^(18-decimals)), NOT price conversion. Assumes 1 token = $1 USD. Safe for current stablecoin-only lending but is a latent bomb if any non-$1 asset becomes lendable. Function name is misleading.

**HIGH (2):**
- H-01: `isPriceFresh()` does not check `answer > 0`. Returns true for zero-price with recent timestamp. Inconsistent with `_getAssetPriceUSDInternal()` which reverts on answer <= 0.
- H-02: Grace period keyed on (borrower, debtAsset, collateralAsset) but HF is user-global. Liquidator can bypass grace period by targeting different collateral asset of same borrower.

**MEDIUM (4):**
- M-01: Stale oracle fallback uses 80% of usdValueCached with no TTL validation on the cached value.
- M-02: feedDecimals > 18 causes underflow revert (bricks all operations for that asset).
- M-03: On-chain _userDebtUSD does not include accrued interest between settlements.
- M-04: Liquidation CEI order — debt reduction happens after addCollateral external call.

**What was CORRECT:**
- L2 sequencer uptime check logic
- HF = max when debt = 0
- _computeSeizure arithmetic with consistent 18-dec inputs
- 48h timelocks on all admin functions
- nonReentrant on liquidate()
- Stale oracle blocks liquidation (safe direction)

### Recurring Pattern Confirmations
- Pattern #6 (decimal normalization) confirmed again — _normalizeToUSD18 is misleadingly named
- Pattern #5 (stale cached oracle) — mitigated with live oracle but residual risk in fallback path
