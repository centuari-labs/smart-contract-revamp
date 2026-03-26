---
name: Arithmetic, Oracle, and Economic Attack Audit 2026-03-25
description: Deep-dive audit of integer arithmetic, oracle security, and economic vectors across CentuariEndpoint, RiskModule, LiquidationEngine, CollateralRegistry, FeeController, CentuariRateOracle. 2 CRITICAL (decimal mismatches in LiquidationEngine), 4 HIGH, 5 MEDIUM.
type: project
---

## Audit: Arithmetic, Oracle, and Economic Attack Vectors (2026-03-25)

**Contracts**: CentuariEndpoint, RiskModule, LiquidationEngine, CollateralRegistry, FeeController, CentuariRateOracle, BalanceLedger, AssetBehaviorRegistry
**Verdict**: REQUEST CHANGES

### CRITICAL (2)
1. **LiquidationEngine.sol:94-96,231-244** — 50% debt cap unenforced. debtToCover (6-dec USDC) compared against maxCoverage (18-dec USD). Cap never triggers. Also seizure computation uses wrong decimal base.
2. **LiquidationEngine.sol:117** — freshCollateralUsdValue divides by 1e18 instead of 10^tokenDecimals. Inflates USD value by 10^12 for USDC collateral, making liquidation impossible for non-18-decimal tokens.

### HIGH (4)
1. **RiskModule.sol:272-297** — _getWeightedCollateralUSD reads live oracle but never checks staleness against maxStaleness. Stale prices used for HF in withdraw()/setAsCollateral().
2. **CentuariEndpoint.sol:304** — Refinance anchor rate check bypassed when anchorRateBPS=0. Fix applied to rollovers but not refinances (Pattern #1).
3. **CentuariEndpoint.sol:374-383** — _processReturns credits arbitrary amounts with zero on-chain validation beyond HSM signature.
4. **LiquidationEngine.sol:216-226** — setAuthorizedCaller/setRateOracle/setLayerZeroEndpoint lack timelock (Pattern #4).

### MEDIUM (5)
1. CentuariEndpoint.sol:327-331 — Refinance debt tracking only records increases, not replacements
2. FeeController.sol:186 — Edge case with zero grossInterest and flat settlement fees
3. CentuariEndpoint.sol:542 — CBT redemption depletes shared pool without accounting deduction (Pattern #7)
4. RiskModule.sol:167-169 — reduceDebtAgainstAsset can underflow, blocking liquidation
5. CentuariEndpoint.sol:184 — debit from available, not locked, bypassing TOCTOU protection

### Recurring Patterns Confirmed
- Pattern #1 (Incomplete Fix): anchor rate bypass on refinance
- Pattern #4 (Missing Timelocks): LiquidationEngine admin setters
- Pattern #6 (Decimal Mismatch): both CRITICALs in LiquidationEngine
- Pattern #7 (Shared Pool): CBT redemption from shared balance
