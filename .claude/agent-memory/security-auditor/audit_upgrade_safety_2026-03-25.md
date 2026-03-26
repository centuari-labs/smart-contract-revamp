---
name: Upgrade Safety and Storage Layout Audit v2 (2026-03-25)
description: UPDATED storage layout audit of all 20 contracts. Prior CRIT-2 findings (state vars after __gap) FIXED. 0 CRITICAL, 0 HIGH, 1 MEDIUM (LiquidationEngine instant admin setters), 2 LOW, 1 INFO. VERDICT: NEEDS MINOR FIX.
type: project
---

## Upgrade Safety and Storage Layout Audit — 2026-03-25

### Scope
All upgradeable and non-upgradeable contracts in src/core/, src/spoke/, src/core/centuari/, src/core/pcbt/.

### Findings Summary

**CRITICAL: 2**

1. **RiskModule.sol — State variables declared in implementation file after `__gap`**
   - Lines 234-236: `_pendingAuthorizedCaller` (address), `_pendingCallerAuthorized` (bool), `_pendingCallerTimelockEnd` (uint256) are declared in the implementation, not in RiskModuleStorage.sol.
   - These occupy storage slots AFTER the `__gap[42]` array in RiskModuleStorage.sol. On any proxy upgrade that changes the implementation bytecode, these slots will be corrupted or lost.
   - `ADMIN_TIMELOCK` (line 237) is a constant — OK, no storage slot.
   - **Fix**: Move all 3 state variables into RiskModuleStorage.sol before `__gap`, reduce `__gap` from 42 to 40 (address+bool pack into 1 slot + uint256 = 2 new slots).

2. **CollateralRegistry.sol — Mapping state variables declared in implementation file after `__gap`**
   - Lines 224-225: `_pendingPriceFeed` (mapping) and `_pendingPriceFeedTimestamp` (mapping) declared in implementation, not in CollateralRegistryStorage.sol.
   - Same corruption risk as RiskModule. Mappings occupy 1 slot each.
   - `PRICE_FEED_TIMELOCK` (line 226) is a constant — OK.
   - **Fix**: Move both mappings into CollateralRegistryStorage.sol before `__gap`, reduce `__gap` from 39 to 37.

**MEDIUM: 1**

3. **LiquidationEngine.sol — `setAuthorizedCaller()` lacks timelock**
   - Line 209: `setAuthorizedCaller(address, bool)` is instant `onlyOwner`, no timelock.
   - RiskModule.sol has 48h timelock for the identical operation (`proposeAuthorizedCaller` / `applyAuthorizedCaller`).
   - An authorized caller can record/reduce arbitrary debt. Instant granting enables "position assassination."
   - **Fix**: Add propose/apply pattern with 48h timelock matching RiskModule. Move pending state vars into LiquidationEngineStorage.sol.

**LOW: 2**

4. **BalanceLedgerStorage.sol — Gap off by 1 (P1-e packing error)**
   - `_riskModule` (address, 20 bytes) + `_paused` (bool, 1 byte) pack into 1 slot, not 2.
   - Gap was reduced by 3 (from 40 to 37) when adding 3 variables, but one pair packs, so it should have been reduced by 2 (to 38).
   - Current: 13 slots + `__gap[37]` = 50. Should be: 12 slots + `__gap[38]` = 50.
   - Impact: 1 wasted gap slot. Not exploitable but makes future slot accounting error-prone.

5. **ProtocolTreasury.sol — Miscategorized as non-upgradeable**
   - Uses `Initializable`, has `_disableInitializers()` in constructor, `initializer` on `initialize()`, and `__gap[48]`.
   - Was listed in Check 5 (non-upgradeable) but is actually upgradeable. SAFE storage layout (1 var + `__gap[48]` = 49 slots).

**INFO: 1**

6. **Inconsistent gap totals across contracts**
   - Gap totals range from 45 to 50 across 13 upgradeable contracts. Not a bug (each contract independently manages its gap), but inconsistency makes auditing harder and increases risk of arithmetic errors.
   - Recommendation: Standardize all contracts to 50-slot total.

### Check Results by Contract

| Contract | Check 1 (Gap) | Check 2 (Init) | Check 3 (Additions) | Check 4 (Impl Vars) |
|---|---|---|---|---|
| CentuariEndpointStorage | SAFE (46) | SAFE | SAFE | SAFE |
| BalanceLedgerStorage | LOW (off by 1) | SAFE | P1-e pack error | SAFE |
| RiskModuleStorage | SAFE (48) | SAFE | SAFE | **CRITICAL** (3 vars in impl) |
| LiquidationEngineStorage | SAFE (48) | SAFE | SAFE | SAFE (no impl state vars) |
| CollateralRegistryStorage | SAFE (48) | SAFE | M-03 correct | **CRITICAL** (2 mappings in impl) |
| AssetBehaviorRegistryStorage | SAFE (49) | SAFE | H-03 correct | SAFE |
| YieldRouterStorage | SAFE (49) | SAFE | SAFE | SAFE |
| FeeControllerStorage | SAFE (48) | SAFE | H-05 correct | SAFE |
| CentuariRateOracleStorage | SAFE (48) | SAFE | H-04 correct | SAFE |
| CentuariRouterStorage | SAFE (47) | SAFE | SAFE | SAFE |
| MarketScheduleRegistryStorage | SAFE (50) | SAFE | SAFE | SAFE |
| WithdrawalRegistryStorage | SAFE (50) | SAFE | SAFE | SAFE |
| ProtocolTreasury | SAFE (49) | SAFE | SAFE | SAFE |

Check 5 (Non-upgradeable): All 7 confirmed SAFE — CentuariBondERC20, CentuariBondERC20Factory, SpokeVaultRWA, SpokeVaultStable, SpokePayout, HubIntentSettler, SettlementLedger.

Check 6 (ERC-7201): No contracts use ERC-7201 namespaced storage. All use traditional layout with `__gap`. Consistent.

### VERDICT: REQUEST CHANGES
The 2 CRITICAL storage safety issues MUST be fixed before any proxy upgrade. State variables in implementation files after `__gap` will be silently corrupted on upgrade.
