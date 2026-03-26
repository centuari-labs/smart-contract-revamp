---
name: BalanceLedger Security Audit 2026-03-26
description: Comprehensive audit of BalanceLedger.sol and BalanceLedgerStorage.sol — 2 HIGH, 5 MEDIUM, 4 LOW, 3 INFO findings. Key issues: stale price in setAsCollateral safety check, missing collateralEligible check, sourceChainId mismatch in reduceCollateral.
type: project
---

## BalanceLedger.sol Audit (2026-03-26)

**Verdict:** REQUEST CHANGES (2 HIGH findings)

### Critical Path Findings

**H-01: setAsCollateral() safety check uses stale cached prices (usdValueCached) via getWeightedCollateralExcluding() while actual HF uses live oracle prices via _getWeightedCollateralUSD(). Price drops between cache refresh and toggle could allow disabling collateral that puts HF below 1.0.**

**Why:** RiskModule has two code paths — getWeightedCollateralExcluding() at line 68 reads `positions[i].usdValueCached`, while _getWeightedCollateralUSD() at line 398 reads live Chainlink. The BalanceLedger.setAsCollateral() calls the stale one.

**How to apply:** When fixing, ensure getWeightedCollateralExcluding() uses the same live oracle path as _getWeightedCollateralUSD(). This is a RiskModule change, not a BalanceLedger change.

**H-02: addCollateral() and setAsCollateral() never check AssetBehaviorRegistry.collateralEligible. Any asset can be used as collateral regardless of governance settings. Error AssetNotCollateralEligible defined in interface but never used.**

### Other Notable Findings

- M-01: reduceCollateral() ignores sourceChainId — could reduce wrong position for multi-chain collateral
- M-02: Unbounded _collateral[user] array — DoS vector for HF computation
- M-03: updateCollateralUsdValue() silently returns if asset not found
- M-04: Single pending writer proposal slot — silent overwrite risk
- M-05: Storage gap arithmetic may be incorrect (comment says "reduced by 5" but actual slot count differs)
- L-01: NatSpec says keys are keccak256() but code uses literal bytes32 comparison
- L-04: pause()/unpause() have no timelock

### Patterns Confirmed Working

- Fee-on-transfer safe deposit via balanceOf before/after
- HF check on withdraw() correctly added
- withdraw() correctly omits whenNotPaused (Invariant #21)
- CEI pattern followed throughout
- nonReentrant on all state-changing external functions
- 48h timelock on authorized writer changes
