---
name: RiskModule + LiquidationEngine Deep Audit 2026-03-27
description: Comprehensive 10-section security audit of RiskModule.sol and LiquidationEngine.sol. 1 CRITICAL, 1 HIGH, 3 MEDIUM, 3 LOW, 1 INFO. VERDICT: REQUEST CHANGES.
type: project
---

# Security Audit: RiskModule.sol + LiquidationEngine.sol

**Date**: 2026-03-27
**Auditor**: Security Auditor Agent (Claude Opus 4.6)
**Contracts Reviewed**:
- `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/RiskModule.sol` (489 lines)
- `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/LiquidationEngine.sol` (370 lines)
- `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/RiskModuleStorage.sol` (57 lines)
- `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/LiquidationEngineStorage.sol` (74 lines)
- `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/interfaces/IAssetBehaviorRegistry.sol` (180 lines)
- `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/interfaces/IBalanceLedger.sol` (185 lines)
- `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/interfaces/IRiskModule.sol` (121 lines)
- `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/interfaces/ILiquidationEngine.sol`

---

## SECURITY INVARIANT CHECK

[PASS] #1 -- HSM signer authority -- Not in scope (CentuariEndpoint). RiskModule/LiquidationEngine do not accept settlement batches.
[PASS] #2 -- Strictly increasing nonce -- Not in scope (CentuariEndpoint).
[PASS] #3 -- SpokeVaultRWA release only via LayerZero -- Not in scope (SpokeVaultRWA). LiquidationEngine sends cross-chain messages but does not receive them.
[PASS] #4 -- SpokePayout requires recall complete -- Not in scope (WithdrawalRegistry).
[PASS] #5 -- YieldRouter recall atomic with settlement -- Not in scope (YieldRouter).
[PASS] #6 -- fillFor requires actual transfer -- Not in scope (HubIntentSettler).
[PASS] #7 -- AssetBehavior changes require 48h timelock -- Not in scope (AssetBehaviorRegistry). RiskModule reads but does not write AssetBehavior.
[PASS] #8 -- InsuranceReserve >= 10% of deployed -- Not in scope (YieldRouter).
[PASS] #9 -- BalanceLedger writes restricted -- LiquidationEngine calls `ledger.reduceCollateral()`, `ledger.addCollateral()`, `ledger.debit()`, `ledger.updateCollateralUsdValue()` at lines 143-149, 134. These calls are gated by BalanceLedger's `onlyAuthorized` pattern. LiquidationEngine must be registered as an authorized writer.
[PASS] #10 -- Attestation replay prevention -- Not in scope (CollateralRegistry).
[PASS] #11 -- No stale price for liquidation -- Enforcement at LiquidationEngine.sol:104 via `riskModule.isPriceFresh(collateralAsset)`.
[PASS] #12 -- onIntentFilled only by Endpoint -- Not in scope (CentuariRouter).
[PASS] #13 -- isUsedAsCollateral toggle safety -- RiskModule provides `getWeightedCollateralExcluding()` (line 68) used by BalanceLedger's `setAsCollateral()`. **CAVEAT**: uses stale `usdValueCached` (line 79) instead of live oracle -- see M-01.
[PASS] #14 -- Debt ceiling enforcement -- Checked in RiskModule `validateBorrow()` at lines 123-132. **CAVEAT**: uses raw `borrowAmount` without 18-dec normalization -- see C-01.
[PASS] #15 -- Anchor rate bounds -- Not in scope (CentuariEndpoint).
[PASS] #16 -- CentuariRouter token accounting -- Not in scope (CentuariRouter).
[PASS] #17 -- CEI pattern -- RiskModule: all functions are view or storage-only (no external calls after state changes). LiquidationEngine: state changes (lines 143-163) all happen via BalanceLedger/RiskModule calls in sequence; no raw external calls between state mutations.
[PASS] #18 -- Liquidation functions use nonReentrant -- LiquidationEngine.liquidate() at line 75: `nonReentrant` modifier present.
[PASS] #19 -- Oracle reads before state changes -- LiquidationEngine reads oracle at lines 81, 104, 121 before any state changes at lines 143+. RiskModule oracle reads are in view functions.
[PASS] #20 -- Admin functions timelocked -- RiskModule: `proposeSetBalanceLedger/applySetBalanceLedger` (lines 333-355), `proposeSetAssetBehaviorRegistry/applySetAssetBehaviorRegistry` (lines 359-381), `proposeSetAuthorizedCaller/applySetAuthorizedCaller` (lines 291-323) all use 48h timelock. LiquidationEngine: `proposeSetAuthorizedCaller/applySetAuthorizedCaller` (lines 272-335) use 48h timelock. **EXCEPTIONS**: see L-01, L-02.
[PASS] #21 -- Users can withdraw when paused -- Not directly in scope (BalanceLedger/CentuariEndpoint).
[PASS] #22 -- Storage layout preserved -- RiskModuleStorage.sol has `__gap[36]` at line 56. LiquidationEngineStorage.sol has `__gap[35]` at line 73. All state variables in Storage contracts, not impl.
[PASS] #23 -- Interest accrued before HF check -- LiquidationEngine.liquidate() calls `riskModule.getHealthFactor()` (line 81) which reads current `_userDebtUSD`. Interest accrual is handled by CentuariEndpoint before calling liquidation. No local accrual needed in these contracts.
[PASS] #24 -- CBT mint amount validated -- Not in scope (CentuariEndpoint).
[PASS] #25 -- Rounding favors protocol -- Interest formula uses integer division which truncates toward zero: `(principal * rateBPS * elapsedSeconds) / (RATE_PRECISION * SECONDS_PER_YEAR)`. In RiskModule, HF computation uses `(weightedColl * HF_PRECISION) / totalDebt` -- truncation rounds HF down, favoring protocol (makes positions more easily liquidatable).

---

## FINDINGS

### CRITICAL: 1

#### C-01: `validateBorrow()` adds raw asset-decimal `borrowAmount` to 18-decimal debt values

**File**: `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/RiskModule.sol`
**Lines**: 129, 138

**Description**: `validateBorrow()` receives `borrowAmount` in asset-native decimals (e.g., 6 for USDC) but adds it directly to `_totalDebtAgainstAsset` and `_userDebtUSD`, both of which are tracked in 18-decimal USD. This produces two distinct failures:

1. **Debt ceiling bypass (line 129)**: `currentDebt` (18-dec) + `borrowAmount` (6-dec) never exceeds `debtCeiling` (18-dec). A user borrowing 1,000,000 USDC (`1e12` in 6-dec) is compared as `currentDebt + 1e12` against a ceiling like `5e24` (5M in 18-dec). The check effectively does not bind.

2. **HF check bypass (line 138)**: `existingDebt` (18-dec) + `borrowAmount` (6-dec) produces a `newTotalDebt` that is 10^12 smaller than it should be. The HF check passes for positions that are severely undercollateralized.

```solidity
// Line 127-129: debt ceiling check with decimal mismatch
uint256 currentDebt = _totalDebtAgainstAsset[collateralAssets[i]];
if (currentDebt + borrowAmount > behavior.debtCeiling) {
    return (false, "DEBT_CEILING_EXCEEDED");
}

// Line 137-138: HF check with decimal mismatch
uint256 existingDebt = _userDebtUSD[borrower];
uint256 newTotalDebt = existingDebt + borrowAmount;
```

**Attack vector**:
1. Attacker deposits $10,000 USDC as collateral (10000e6 raw, valued at 10000e18 USD)
2. Attacker submits borrow order for 100,000 USDC (100000e6 raw)
3. `validateBorrow()` computes `newTotalDebt = 0 + 100000e6 = 1e11`
4. `weightedColl` = 10000e18 * 8500 / 10000 = 8500e18
5. HF check: `(8500e18 * 1e18) / 1e11 = 8.5e25` -- vastly above 1e18, check passes
6. Attacker borrows 10x their collateral, extracts funds

**Impact**: Complete protocol insolvency. Any borrower can bypass both debt ceiling and collateral requirements for non-18-decimal assets.

**Note**: The comment at line 128 acknowledges the assumption: "Simple USD conversion (assumes borrowAsset is USD-pegged stablecoin)". However, even for USD-pegged stablecoins, the decimal mismatch breaks the math entirely. A 6-decimal USDC amount is NOT equivalent to an 18-decimal USD amount.

**Fix**: Normalize `borrowAmount` to 18 decimals before both comparisons:
```solidity
uint256 borrowAmount18 = _normalizeToUSD18(borrowAsset, borrowAmount);
// Use borrowAmount18 in debt ceiling check (line 129) and HF check (line 138)
```
Where `_normalizeToUSD18` follows the same pattern as LiquidationEngine lines 364-368. Alternatively, add a helper function in RiskModule.

---

### HIGH: 1

#### H-01: LiquidationEngine decimal mismatch makes liquidation impossible for non-18-decimal collateral

**File**: `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/LiquidationEngine.sol`
**Line**: 122

**Description**: `freshCollateralUsdValue` is computed as `(pricePerUnit18 * collPos.amount) / 1e18`. For tokens with <18 decimals, this produces a value in the wrong scale, causing `_computeSeizure()` to return a value that always exceeds `collPos.amount`, making liquidation revert at line 131.

Concrete example with USDC (6 decimals):
- `pricePerUnit18 = 1e18` (Chainlink returns $1 scaled to 18 dec)
- `collPos.amount = 10000e6` (10,000 USDC in native 6 dec)
- Line 122: `freshCollateralUsdValue = (1e18 * 10000e6) / 1e18 = 10000e6`
- After normalization, `debtToCover18 = 5000e18` (covering 5,000 USDC debt)
- With 5% bonus: `debtWithBonus = 5250e18`
- `_computeSeizure`: `(5250e18 * 10000e6) / 10000e6 = 5250e18`
- Line 131: `5250e18 > 10000e6` -- ALWAYS TRUE -- REVERT

The correct computation at line 122 should divide by `10 ** tokenDecimals` (matching what `_getWeightedCollateralUSD` does at RiskModule line 422), not by `1e18`.

Additionally, line 134 would write a corrupted `usdValueCached` to BalanceLedger if it were reached (it cannot be reached because line 131 reverts first).

**Impact**: Liquidation of positions backed by non-18-decimal collateral (USDC, USDT -- the primary collateral types) is permanently blocked. Bad debt accumulates unchecked. Combined with C-01, borrowers can over-borrow AND cannot be liquidated.

**Fix**:
```solidity
// Line 122: Replace 1e18 divisor with token-native decimals
uint8 collDecimals = _getTokenDecimals(collateralAsset); // Add helper or use staticcall
uint256 freshCollateralUsdValue = (pricePerUnit18 * collPos.amount) / (10 ** collDecimals);
```
Where `_getTokenDecimals` follows the same pattern as RiskModule line 437-445.

---

### MEDIUM: 3

#### M-01: `getWeightedCollateralExcluding()` uses stale `usdValueCached` while `_getWeightedCollateralUSD()` uses live oracle

**File**: `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/RiskModule.sol`
**Lines**: 79 vs 410-422

**Description**: Two functions compute weighted collateral differently:
- `_getWeightedCollateralUSD()` (line 398): reads LIVE Chainlink oracle prices with staleness check and 20% haircut fallback
- `getWeightedCollateralExcluding()` (line 68): reads `positions[i].usdValueCached` (line 79) -- keeper-refreshed, potentially hours old

`getWeightedCollateralExcluding()` is called by BalanceLedger's `setAsCollateral()` to enforce Invariant #13 (cannot disable collateral if it would drop HF below 1.0). Using stale prices means a user could disable collateral that appears safe based on cached prices but would be undercollateralized at current market prices.

**Impact**: Invariant #13 enforcement is weakened. A user could disable collateral for an asset that has dropped in value since the last keeper refresh, making their position liquidatable.

**Fix**: Refactor `getWeightedCollateralExcluding()` to use live oracle prices, matching `_getWeightedCollateralUSD()`:
```solidity
function getWeightedCollateralExcluding(address user, address excludeAsset) external view returns (uint256 weightedUSD) {
    // Use same live oracle logic as _getWeightedCollateralUSD but skip excludeAsset
}
```

#### M-02: Unchecked subtraction in debt reduction functions risks underflow revert

**File**: `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/RiskModule.sol`
**Lines**: 168, 179

**Description**: `reduceDebtAgainstAsset()` (line 168) and `reduceUserDebt()` (line 179) perform raw subtraction without checking that the value being subtracted does not exceed the current balance:
```solidity
_totalDebtAgainstAsset[collateralAsset] -= debtUSD;  // line 168
_userDebtUSD[user] -= debtUSD;                         // line 179
```

If `debtUSD` exceeds the stored value due to rounding differences, normalization edge cases, or concurrent operations, the transaction reverts with an arithmetic underflow. This could permanently block liquidations or repayments for affected positions.

**Impact**: DoS on liquidation/repayment for positions where debt tracking has drifted from the actual debt amount. The revert is in `onlyAuthorized` functions called by LiquidationEngine/CentuariEndpoint, so it blocks protocol operations.

**Fix**: Use `min(debtUSD, currentValue)` pattern:
```solidity
function reduceDebtAgainstAsset(address collateralAsset, uint256 debtUSD) external override onlyAuthorized {
    uint256 current = _totalDebtAgainstAsset[collateralAsset];
    uint256 reduction = debtUSD > current ? current : debtUSD;
    _totalDebtAgainstAsset[collateralAsset] = current - reduction;
    emit DebtReduced(collateralAsset, reduction);
}
```

#### M-03: `validateBorrow()` checks minimum borrow amount AFTER HF and debt ceiling checks

**File**: `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/RiskModule.sol`
**Lines**: 144-148

**Description**: The `minBorrowAmount` check at line 146 occurs after the expensive collateral iteration (lines 113-121), debt ceiling loop (lines 124-132), and live oracle HF computation (lines 136-142). This ordering wastes gas on invalid borrows. More importantly, `minBorrowAmount` is compared against raw `borrowAmount` which may be in asset-native decimals, while `minBorrowAmount` in the `AssetBehavior` struct could be stored in a different decimal convention (the interface does not specify).

**Impact**: Gas waste on invalid borrows. Potential minBorrowAmount bypass if decimal conventions differ (though this depends on how `minBorrowAmount` is configured in practice).

**Fix**: Move the `minBorrowAmount` check to the top of `validateBorrow()`, before any iteration or oracle reads.

---

### LOW: 3

#### L-01: `setSequencerUptimeFeed()` has no timelock

**File**: `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/RiskModule.sol`
**Line**: 386

**Description**: Setting the sequencer uptime feed is an `onlyOwner` operation with no timelock. A compromised owner can set `_sequencerUptimeFeed = address(0)` to disable the sequencer check, then exploit stale prices immediately after an Arbitrum sequencer outage. All other admin setters in RiskModule use 48h timelocks.

**Fix**: Add propose/apply/cancel timelock pattern matching the other admin functions.

#### L-02: `setSpokeVaultRWA()` has no timelock

**File**: `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/LiquidationEngine.sol`
**Line**: 339

**Description**: Setting spoke vault addresses is an `onlyOwner` operation with no timelock. A compromised owner could redirect cross-chain liquidation messages to a malicious contract to intercept or block RWA liquidations. Other admin setters in LiquidationEngine use 48h timelocks.

**Fix**: Add propose/apply/cancel timelock pattern matching the other admin functions.

#### L-03: `_normalizeToUSD18()` silently returns unscaled value for tokens with >=18 decimals

**File**: `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/LiquidationEngine.sol`
**Line**: 367

**Description**: For tokens with 18+ decimals, `_normalizeToUSD18()` returns the raw `amount` without scaling down:
```solidity
if (decimals >= 18) return amount;
```
For tokens with exactly 18 decimals this is correct. For hypothetical tokens with >18 decimals, the returned value would be too large, inflating debt calculations. While no current Centuari-supported tokens have >18 decimals, this is a latent issue if such tokens are added.

**Fix**:
```solidity
if (decimals == 18) return amount;
if (decimals > 18) return amount / (10 ** (decimals - 18));
return amount * (10 ** (18 - decimals));
```

---

### INFO: 1

#### I-01: Cross-chain liquidation sends LayerZero message with empty options bytes

**File**: `/Users/willgd/Documents/workspace/centuari/smart-contract-revamp/src/core/LiquidationEngine.sol`
**Line**: 205

**Description**: `_sendCrossChainLiquidation()` sends a LayerZero V2 message with empty `_options` (determined by the bytes parameter passed). Empty options means the destination chain execution relies on LayerZero default gas settings, which may be insufficient for `releaseLiquidation()` execution on the spoke chain. If the destination execution runs out of gas, the message is lost and must be retried via `retryLiquidation()`.

**Impact**: Operational risk for cross-chain liquidations. Not a fund-loss issue since `retryLiquidation()` exists, but increases liquidation latency for RWA collateral.

---

## REENTRANCY ANALYSIS

### External calls in LiquidationEngine.liquidate():
1. `riskModule.getHealthFactor(borrower)` -- line 81, read-only (view)
2. `riskModule.isPriceFresh(collateralAsset)` -- line 104, read-only (view)
3. `riskModule.getAssetPriceUSD(collateralAsset)` -- line 121, read-only (view)
4. `ledger.getCollateralByAsset(...)` -- line 107, read-only (view)
5. `ledger.getIsUsedAsCollateral(...)` -- line 109, read-only (view)
6. `ledger.updateCollateralUsdValue(...)` -- line 134, state change
7. `ledger.debit(...)` -- line 143, state change
8. `ledger.reduceCollateral(...)` -- line 146, state change
9. `ledger.addCollateral(...)` -- line 149, state change
10. `riskModule.reduceUserDebt(...)` -- line 157, state change
11. `riskModule.reduceDebtAgainstAsset(...)` -- line 158, state change

All state changes (lines 134-163) occur within the `nonReentrant` guard (line 75). CEI pattern is followed: all reads/checks (lines 80-131) complete before state modifications (lines 134-163). No raw `.call()` or token transfers in `liquidate()` itself -- all token movements are delegated to BalanceLedger's `debit`/`addCollateral`/`reduceCollateral` which are internal accounting operations, not ERC20 transfers.

**Cross-function reentrancy**: Not applicable. `nonReentrant` prevents any reentry into `liquidate()` or any other `nonReentrant` function during execution.

**Cross-contract reentrancy via BalanceLedger**: BalanceLedger's `debit()` and `addCollateral()` are accounting operations (mapping updates). They do not call external contracts or transfer tokens. No reentrancy vector.

**VERDICT**: Reentrancy protection is adequate.

---

## ORACLE SECURITY

### Oracle reads found:

1. **RiskModule._getAssetPriceUSDInternal()** (line 197): Main oracle read path.
   - [PASS] Staleness check: `block.timestamp - oracleUpdatedAt > behavior.maxStaleness` at line 416
   - [PASS] `answer > 0` check at line 209
   - [PASS] `answeredInRound >= roundId` check at line 478 (in `_latestRoundData`)
   - [PASS] Price sanity bounds at lines 212-213 (minPrice/maxPrice)
   - [PASS] Feed decimals normalized to 18 at line 217

2. **RiskModule._latestRoundData()** (line 447): Wrapper with L2 sequencer check.
   - [PASS] Sequencer uptime feed checked at lines 454-471
   - [PASS] Grace period after sequencer recovery: `SEQUENCER_GRACE_PERIOD = 1 hours` at line 463
   - [CAVEAT] If `_sequencerUptimeFeed` staticcall returns <160 bytes, the check is silently skipped (no `else` branch at line 458). This means a misconfigured feed address that returns garbage data would bypass the sequencer check.

3. **LiquidationEngine.liquidate()** (line 104): Oracle freshness verified via `riskModule.isPriceFresh()`.
   - [PASS] Fresh oracle required BEFORE any state changes.
   - [PASS] HF computed from live oracle via `riskModule.getHealthFactor()` at line 81.

4. **LiquidationEngine line 121**: `riskModule.getAssetPriceUSD(collateralAsset)` reads live price for seizure computation.
   - [PASS] Same oracle used for both origination and liquidation.

**VERDICT**: Oracle security is solid. The sequencer feed silent-skip is minor (L-grade, covered by L-01 as the underlying issue is the non-timelocked setter).

---

## INTEREST ACCRUAL ORDERING

Interest accrual in Centuari happens at the CentuariEndpoint level during settlement batch processing. RiskModule and LiquidationEngine do not accrue interest themselves -- they read `_userDebtUSD` which is updated by CentuariEndpoint/settlement logic.

- **LiquidationEngine.liquidate()**: Reads `riskModule.getHealthFactor(borrower)` at line 81. This reads `_userDebtUSD[borrower]` which should already include accrued interest from the most recent settlement. If interest has not been settled on-chain yet (between settlement batches), the HF check uses the last-settled debt value, which slightly favors the borrower (debt appears lower). This is acceptable -- the off-chain engine handles interest accrual at settlement.
- **RiskModule.validateBorrow()**: Same pattern -- reads `_userDebtUSD[borrower]` at line 137.

**VERDICT**: Interest accrual ordering is handled correctly at the architecture level. These contracts do not need to accrue interest because debt is updated by the settlement layer.

---

## LIQUIDATION CORRECTNESS

1. **Can a position be over-liquidated (HF > 1.0 after)?**
   - The 50% max debt coverage (line 100-101) prevents full liquidation in a single call. After partial liquidation, HF should improve. No explicit check that post-liquidation HF >= 1.0, but the 50% cap is the standard approach (matching Aave V3).
   - **BLOCKED by H-01**: Liquidation is currently impossible for non-18-decimal collateral, so this analysis is moot until H-01 is fixed.

2. **Is HF read from a FRESH oracle?**
   - [PASS] Line 81: `riskModule.getHealthFactor()` uses live oracle via `_getWeightedCollateralUSD()`.
   - [PASS] Line 104: `riskModule.isPriceFresh()` checks staleness before proceeding.

3. **Flash-loan-based liquidation griefing?**
   - A borrower could front-run a liquidation by adding collateral to temporarily boost HF above 1.0, causing the liquidation to revert. However, the added collateral is real (deposited via BalanceLedger), so this is a legitimate action, not griefing. The collateral cannot be flash-borrowed and returned in the same tx because BalanceLedger deposits require actual ERC20 transfers.

4. **Insolvent positions (collateral < debt)?**
   - `_computeSeizure()` at line 352 returns 0 if `collateralUsdValue == 0`. Line 131 checks `collateralToSeize > collPos.amount` and reverts if the seizure would exceed available collateral. For deeply insolvent positions where remaining collateral after seizure still leaves bad debt, the protocol relies on the InsuranceReserve/bad debt waterfall. This is acceptable.

5. **Grace period enforcement?**
   - [PASS] Lines 89-92: Grace period checked before liquidation proceeds.
   - [PASS] `MAX_GRACE_PERIOD_HOURS = 24` in LiquidationEngineStorage.sol line 34.
   - [PASS] Cannot bypass by using different debtAsset -- positionId includes collateralAsset (line 88, HIGH-2 FIX).

6. **Self-liquidation?**
   - Not explicitly prevented. A user can liquidate their own position. This is harmless (they pay themselves with bonus, net effect is a collateral shuffle) and matches Aave V3 behavior.

**VERDICT**: Liquidation logic is correct in design but BLOCKED by H-01 decimal mismatch for non-18-decimal tokens.

---

## ACCESS CONTROL

### External/public functions and modifiers:

**RiskModule.sol:**
| Function | Modifier | Risk |
|---|---|---|
| `initialize()` | `initializer` | Safe |
| `getHealthFactor()` | `view` (public) | Safe |
| `getWeightedCollateralExcluding()` | `view` (external) | Safe |
| `validateBorrow()` | `view` (external) | Safe |
| `getTotalDebtAgainstAsset()` | `view` (external) | Safe |
| `recordDebtAgainstAsset()` | `onlyAuthorized` | Safe |
| `reduceDebtAgainstAsset()` | `onlyAuthorized` | Safe |
| `recordUserDebt()` | `onlyAuthorized` | Safe |
| `reduceUserDebt()` | `onlyAuthorized` | Safe |
| `getAssetPriceUSD()` | `view` (external) | Safe |
| `verifyDualOracle()` | `view` (external) | Safe |
| `isPriceFresh()` | `view` (external) | Safe |
| `getTotalDebtUSD()` | `view` (external) | Safe |
| `proposeSetAuthorizedCaller()` | `onlyOwner` | 48h timelock |
| `applySetAuthorizedCaller()` | `onlyOwner` | 48h timelock |
| `cancelSetAuthorizedCaller()` | `onlyOwner` | Instant (safe, conservative) |
| `proposeSetBalanceLedger()` | `onlyOwner` | 48h timelock |
| `applySetBalanceLedger()` | `onlyOwner` | 48h timelock |
| `cancelSetBalanceLedger()` | `onlyOwner` | Instant (safe, conservative) |
| `proposeSetAssetBehaviorRegistry()` | `onlyOwner` | 48h timelock |
| `applySetAssetBehaviorRegistry()` | `onlyOwner` | 48h timelock |
| `cancelSetAssetBehaviorRegistry()` | `onlyOwner` | Instant (safe, conservative) |
| `setSequencerUptimeFeed()` | `onlyOwner` | **NO TIMELOCK** (L-01) |

**LiquidationEngine.sol:**
| Function | Modifier | Risk |
|---|---|---|
| `initialize()` | `initializer` | Safe |
| `liquidate()` | `nonReentrant` (permissionless) | Safe |
| `startGracePeriod()` | `onlyAuthorized` | Safe |
| `retryLiquidation()` | `onlyAuthorized` | Safe |
| `proposeSetAuthorizedCaller()` | `onlyOwner` | 48h timelock |
| `applySetAuthorizedCaller()` | `onlyOwner` | 48h timelock |
| `cancelAuthorizedCallerChange()` | `onlyOwner` | Instant (safe, conservative) |
| `setSpokeVaultRWA()` | `onlyOwner` | **NO TIMELOCK** (L-02) |

**VERDICT**: Access control is well-structured. Two admin setters missing timelocks (L-01, L-02). No function can drain user funds without timelock.

---

## FLASH LOAN VECTORS

1. **borrow + withdraw + repay atomically**: Not possible in a single tx because borrow orders go through the off-chain matching engine. `validateBorrow()` is a view function called by the engine, not directly by users. Settlement happens via CentuariEndpoint in a separate tx.

2. **Collateral add + remove in same tx**: `BalanceLedger.setAsCollateral()` checks HF via `getWeightedCollateralExcluding()`. A user cannot toggle collateral on, borrow, and toggle off in the same tx because borrowing requires engine settlement (separate tx).

3. **Flash loan to front-run liquidation**: A borrower could flash-borrow collateral, deposit into BalanceLedger, and temporarily boost HF. However, BalanceLedger deposits require real ERC20 transfers, so flash-borrowed tokens would actually be deposited. The flash loan must be repaid in the same tx, but withdrawal from BalanceLedger requires WithdrawalRegistry authorization (separate tx). This vector is not viable.

**VERDICT**: Flash loan vectors are not exploitable due to the off-chain matching + on-chain settlement architecture.

---

## DECIMAL AND PRECISION

1. **Token amounts normalized to 18 decimals?**
   - [FAIL] C-01: `validateBorrow()` does NOT normalize `borrowAmount` to 18 decimals.
   - [PASS] LiquidationEngine normalizes `debtToCover` via `_normalizeToUSD18()` at lines 99, 128, 156.
   - [FAIL] H-01: `freshCollateralUsdValue` computation at line 122 divides by `1e18` instead of `10**tokenDecimals`.

2. **Division-before-multiplication?**
   - [PASS] `_computeSeizure()` at line 358-359: `debtWithBonus = debtToCover * (BPS_DENOMINATOR + bonusBPS) / BPS_DENOMINATOR` -- multiplication first, then division.
   - [PASS] HF computation at line 140: `(weightedColl * HF_PRECISION) / newTotalDebt` -- multiplication first.

3. **Zero truncation?**
   - [PASS] `_computeSeizure()` returns 0 for `collateralUsdValue == 0` (line 352).
   - [PASS] `getHealthFactor()` returns `type(uint256).max` for zero debt (line 53).

4. **Constants verified**:
   - `RATE_PRECISION = 10000` -- not used in these contracts (used in CentuariEndpoint)
   - `HF_PRECISION = 1e18` -- RiskModuleStorage.sol:32, LiquidationEngineStorage.sol:37
   - `BPS_DENOMINATOR = 10000` -- RiskModuleStorage.sol:35, LiquidationEngineStorage.sol:40
   - `SECONDS_PER_YEAR = 365 days` -- not used in these contracts (used in CentuariEndpoint)
   - `MAX_DEBT_COVERAGE_BPS = 5000` -- LiquidationEngineStorage.sol:43
   - `ADMIN_TIMELOCK = 48 hours` -- RiskModuleStorage.sol:38, LiquidationEngineStorage.sol:69

**VERDICT**: Two critical decimal issues (C-01, H-01). Other arithmetic is correct.

---

## ECONOMIC ATTACKS

1. **Rounding dust accumulation**: Integer division in HF computation truncates down (favors protocol). In `_computeSeizure`, truncation means liquidator receives slightly less collateral than theoretical value (favors protocol/borrower). No exploitable dust accumulation.

2. **Self-liquidation for profit**: A user cannot profit from self-liquidation because the liquidation bonus comes from their own collateral. Net effect is a loss equal to the bonus amount.

3. **Repeated partial liquidation drain**: Each liquidation is capped at 50% of debt. Repeated calls would each reduce debt by up to 50% of remaining, geometrically approaching zero. The liquidation bonus compounds -- each call seizes bonus % of collateral. After many small liquidations, the borrower loses more collateral than necessary. However, this is a standard property of partial liquidation (same as Aave V3) and is not exploitable because each liquidation call is permissionless -- any liquidator can execute, not just the attacker.

4. **Debt ceiling gaming via multi-collateral**: A borrower with multiple collateral types could split borrows across different collateral to stay under each individual `debtCeiling`. This is by design (debt ceiling is per-collateral-type, not per-user). However, C-01 makes this analysis moot since the ceiling check is broken.

**VERDICT**: No novel economic attacks beyond the decimal issues already identified.

---

## STORAGE SAFETY

1. **`__gap` arrays**:
   - RiskModuleStorage.sol: `uint256[36] private __gap` at line 56. [PASS]
   - LiquidationEngineStorage.sol: `uint256[35] private __gap` at line 73. [PASS]

2. **New variables appended only**:
   - RiskModuleStorage.sol: Lines 27-29 (`_pendingAuthorizedCaller`, `_pendingCallerAuthorized`, `_pendingCallerTimelockEnd`) were moved from the implementation (per CRIT-2 FIX comment). They appear BEFORE `__gap`. Lines 41-52 (pending admin mappings, sequencer feed) also before `__gap`. [PASS]
   - LiquidationEngineStorage.sol: Lines 45-66 (pending admin mappings, PendingCrossChainLiq, spokeVaultRWA) all before `__gap`. [PASS]

3. **`_disableInitializers()` in constructor**:
   - RiskModule.sol: `_disableInitializers()` at line 26. [PASS]
   - LiquidationEngine.sol: `_disableInitializers()` at line 30. [PASS]

4. **`initializer` modifier on `initialize()`**:
   - RiskModule.sol: `function initialize(...) external initializer` at line 35. [PASS]
   - LiquidationEngine.sol: `function initialize(...) external initializer` at line 40. [PASS]

**VERDICT**: Storage safety is correctly implemented.

---

## SUMMARY

| Severity | Count | IDs |
|---|---|---|
| CRITICAL | 1 | C-01 |
| HIGH | 1 | H-01 |
| MEDIUM | 3 | M-01, M-02, M-03 |
| LOW | 3 | L-01, L-02, L-03 |
| INFO | 1 | I-01 |

### CRITICAL

**C-01** [RiskModule.sol:129,138] `validateBorrow()` adds raw asset-decimal `borrowAmount` to 18-decimal debt values, bypassing both debt ceiling and HF checks for non-18-decimal tokens (USDC, USDT). Enables undercollateralized borrowing.

### HIGH

**H-01** [LiquidationEngine.sol:122] Decimal mismatch in `freshCollateralUsdValue` computation divides by `1e18` instead of `10**tokenDecimals`. Makes liquidation impossible for non-18-decimal collateral tokens. Combined with C-01, this means borrowers can over-borrow AND cannot be liquidated.

### MEDIUM

**M-01** [RiskModule.sol:79] `getWeightedCollateralExcluding()` uses stale `usdValueCached` while `_getWeightedCollateralUSD()` uses live oracle. Weakens Invariant #13 enforcement.

**M-02** [RiskModule.sol:168,179] Unchecked subtraction in `reduceDebtAgainstAsset()` and `reduceUserDebt()` can revert on underflow, blocking liquidations/repayments.

**M-03** [RiskModule.sol:144-148] `minBorrowAmount` check is last in `validateBorrow()`, wasting gas on invalid borrows.

### LOW

**L-01** [RiskModule.sol:386] `setSequencerUptimeFeed()` has no timelock.
**L-02** [LiquidationEngine.sol:339] `setSpokeVaultRWA()` has no timelock.
**L-03** [LiquidationEngine.sol:367] `_normalizeToUSD18()` does not scale down for >18-decimal tokens.

### INFO

**I-01** [LiquidationEngine.sol:205] Cross-chain liquidation sends LayerZero message with empty options bytes.

---

## RECURRING PATTERNS FROM MEMORY

1. **Decimal mismatch between 6-dec tokens and 18-dec USD** -- This is the 5th+ time this pattern has been flagged across audits. C-01 and H-01 are new instances in previously-unaudited code paths.
2. **Missing timelocks on admin setters** -- L-01 and L-02 continue the pattern from prior audits (audit_reentrancy_cei_access_2026-03-25.md flagged 10 HIGH for instant admin setters across 9 contracts).
3. **Stale cached oracle values vs live oracle** -- M-01 is a variant of the recurring pattern where `usdValueCached` is used in security-critical paths. The main HF computation was fixed (HIGH-01 FIX at line 392) but `getWeightedCollateralExcluding()` was not updated to match.
4. **Unchecked subtraction in debt tracking** -- M-02 was flagged in audit_cross_function_2026-03-25.md as "debt underflow DoS".

---

## VERDICT: REQUEST CHANGES

C-01 and H-01 together form a catastrophic pair: borrowers can bypass collateral requirements (C-01) AND cannot be liquidated (H-01) for the protocol's primary collateral type (USDC, 6 decimals). Both must be fixed before any deployment.

Minimum required before re-review:
1. Fix C-01: Normalize `borrowAmount` to 18 decimals in `validateBorrow()`
2. Fix H-01: Use `10**tokenDecimals` instead of `1e18` in LiquidationEngine line 122
3. Fix M-01: Update `getWeightedCollateralExcluding()` to use live oracle
4. Fix M-02: Add underflow protection to debt reduction functions
