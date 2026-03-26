---
name: Recurring Vulnerability Patterns
description: Cross-audit patterns that recur in Centuari contracts — use as checklist items on every future review
type: feedback
---

## Recurring Vulnerability Patterns (observed across 2026-03-23 and 2026-03-24 audits)

### 1. Incomplete Fix Propagation
Fix applied to one code path but not all paths reaching the same resource.
**Example**: SpokeVaultRWA lzReceive() got srcEid+sender checks (C-08 fix), but releaseLiquidation() — which does the same thing — was missed.
**Why:** Developers fix the reported location without searching for all callers/paths to the same sensitive operation.
**How to apply:** On every fix review, grep for ALL code paths that reach the same state change or external call. Verify each one independently.

### 2. Accounting Without Token Transfer
Ledger/registry accounting is complete, but the actual ERC20 safeTransfer is missing.
**Example**: LiquidationEngine.liquidate() reduces collateral and debt in accounting but never transfers tokens to/from the liquidator. CentuariBondERC20.redeem() burns CBT but never transfers underlying.
**Why:** Accounting logic is implemented first, transfer logic deferred, then forgotten.
**How to apply:** For every function that modifies a balance mapping, check: is there a corresponding safeTransfer/safeTransferFrom? If not, flag it.

### 3. Request Queues Without Escrow
A queue records a user's intent (withdrawal, early exit) but does not lock the subject asset at request time.
**Example**: PCBTVault.requestWithdrawal() records shares to burn at maturity but does not lock or burn them. User can transfer shares away, then _burn reverts at processing time, blocking the entire queue.
**Why:** Queue patterns default to "record request" without considering the custody gap between request and fulfillment.
**How to apply:** For every queue/request pattern, ask: what happens if the user moves the asset between request and fulfillment? If fulfillment would fail, shares/tokens must be locked at request time.

### 4. Missing Timelocks on Admin Setters
Critical configuration setters (oracle address, signer key, fee parameters) callable by owner with no delay.
**Example**: CentuariEndpoint admin setters for signer/oracle/fee addresses have no timelock. PCBTVault admin functions lack timelock.
**Why:** Admin functions are added for operational convenience without considering governance attack surface.
**How to apply:** Every setter that could affect user funds if set maliciously needs either a timelock or multisig requirement.

### 5. Stale Cached Oracle Values in Health Factor
HF computation reads cached USD values from storage rather than fetching fresh oracle prices.
**Example**: RiskModule._getWeightedCollateralUSD() reads positions[i].usdValueCached which may be hours old, rather than calling Chainlink at HF-check time.
**Why:** Fresh oracle calls are expensive and the keeper-based refresh pattern creates a staleness window.
**How to apply:** Any function that gates a financial decision (liquidation, borrowing, collateral toggle) on HF must either use fresh prices or enforce a maximum staleness on cached values.

### 6. Decimal Normalization Inconsistency Between Code Paths
The same logical operation (debt reduction) normalizes token decimals in one code path but not another.
**Example**: CentuariEndpoint._processLiquidations() normalizes debtRepaid to 18 decimals before calling RiskModule.reduceUserDebt(). But LiquidationEngine.liquidate() passes raw 6-decimal debtToCover directly. Result: permissionless liquidation path barely reduces debt.
**Why:** Two different developers/audits implemented the same operation independently, one got normalization right and the other didn't.
**How to apply:** For every value passed to RiskModule (recordUserDebt, reduceUserDebt, recordDebtAgainstAsset, reduceDebtAgainstAsset), verify the caller normalizes to 18 decimals. Search all callers of these functions.

### 7. Shared Token Pool Without Accounting Separation
Multiple logical reserves (user deposits, CBT redemption backing, protocol fees) share the same ERC20 balance on a contract without earmarked accounting.
**Example**: BalanceLedger holds all user deposits AND backs CBT redemptions from the same token balance. transferOut() sends tokens without deducting from any user's balance, depleting the shared pool.
**Why:** Simplicity — one contract holds everything. Accounting separation adds complexity but is essential for solvency.
**How to apply:** For every transferOut/safeTransfer from a contract that pools multiple users' funds, verify it deducts from a specific accounting entry, not just the raw balance.

### 8. State Variables Declared in Implementation Files After `__gap`
Upgradeable contracts declare state variables in the implementation `.sol` file instead of the companion `*Storage.sol` file. These variables occupy storage slots AFTER the `__gap` array. On any proxy upgrade that changes the implementation bytecode, these slots are silently corrupted or lost.
**Example**: RiskModule.sol lines 234-236 declare `_pendingAuthorizedCaller` (address), `_pendingCallerAuthorized` (bool), `_pendingCallerTimelockEnd` (uint256) in the implementation, not in RiskModuleStorage.sol. CollateralRegistry.sol lines 224-225 declare `_pendingPriceFeed` (mapping) and `_pendingPriceFeedTimestamp` (mapping) in the implementation.
**Why:** Developers add timelock state variables as part of a fix (e.g., H-03 timelock for setAuthorizedCaller) directly in the implementation file where the fix logic lives, rather than in the Storage contract where they belong.
**How to apply:** For every upgradeable contract, grep for `internal` or `private` non-constant state variable declarations in the implementation file (not *Storage.sol). Constants are safe (no storage slot). Any non-constant state variable in the implementation file is a CRITICAL finding.
