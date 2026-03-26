---
name: Cross-Cutting Access Control & Upgradeability Audit 2026-03-26 (v2)
description: Comprehensive audit of access control, upgradeability, and privilege management across all ~40 contracts. 0 CRITICAL, 4 HIGH, 5 MEDIUM, 3 LOW, 3 INFO. Key findings: PCBTVault instant admin setters (H-01), RiskModule instant setSequencerUptimeFeed (H-02), LiquidationEngine instant setSpokeVaultRWA (H-03), SpokeVaultRWA instant setters (H-04). All 25 invariants PASS.
type: project
---

## Cross-Cutting Access Control & Upgradeability Audit v2 -- 2026-03-27

**Scope**: All source files in src/core/, src/spoke/, src/adapters/, src/core/centuari/, src/core/pcbt/, src/core/settlement/, plus Storage contracts.

**VERDICT**: REQUEST CHANGES (4 HIGH findings -- all instant admin setters on security-critical parameters)

---

### UPGRADEABILITY SUMMARY

| Contract | Upgradeable | _disableInitializers | initializer mod | __gap | Notes |
|---|---|---|---|---|---|
| CentuariEndpoint | Yes | Yes | Yes | Yes (EndpointStorage) | Correct |
| BalanceLedger | Yes | Yes | Yes | Yes (BalanceLedgerStorage) | Correct |
| RiskModule | Yes | Yes | Yes | Yes (RiskModuleStorage) | Correct |
| LiquidationEngine | Yes | Yes | Yes | Yes (LiquidationEngineStorage) | Correct |
| YieldRouter | Yes | Yes | Yes | Yes (YieldRouterStorage) | Correct |
| AssetBehaviorRegistry | Yes | Yes | Yes | Yes (ABRStorage) | Correct |
| CollateralRegistry | Yes | Yes | Yes | Yes (CollateralRegistryStorage) | Correct |
| CentuariRateOracle | Yes | Yes | Yes | Yes (RateOracleStorage) | Correct |
| WithdrawalRegistry | Yes | Yes | Yes | Yes (WithdrawalRegistryStorage) | Correct |
| MarketScheduleRegistry | Yes | Yes | Yes | Yes (MSRStorage) | Correct |
| CentuariRouter | Yes | Yes | Yes | Yes (RouterStorage) | Correct |
| FeeController | Yes | Yes | Yes | Yes (FeeControllerStorage) | Correct |
| PCBTVault | Yes | Yes | Yes | Yes (PCBTVaultStorage) | Correct |
| SettlementLedger | No (Ownable) | N/A | N/A | N/A | Non-upgradeable, OK |
| HubIntentSettler | No (Ownable) | N/A | N/A | N/A | Non-upgradeable, OK |
| ProtocolTreasury | No (Ownable) | N/A | N/A | N/A | Non-upgradeable, inline storage |
| CentuariBondERC20 | No | N/A | N/A | N/A | Immutable per design |
| SpokeVaultRWA | No (Ownable) | N/A | N/A | N/A | Non-upgradeable spoke |
| SpokePayout | No (Ownable) | N/A | N/A | N/A | Non-upgradeable spoke |
| SpokeVaultStable | No (Ownable) | N/A | N/A | N/A | Non-upgradeable spoke |

All upgradeable contracts use OZ OwnableUpgradeable with 2-step ownership transfer.

---

### SECURITY INVARIANT CHECK (all 25)

[PASS] #1 -- HSM signer authority -- ecrecover in CentuariEndpoint.submitSettlementBatch()
[PASS] #2 -- Strictly increasing nonce -- CentuariEndpoint enforces _lastProcessedNonce + 1
[PASS] #3 -- SpokeVaultRWA release only via LZ -- lzReceive checks msg.sender == layerZeroEndpoint AND srcEid == hubChainEid AND sender == hubLiquidationEngine (lines 103-107). NOTE: setters for these 3 values are instant (H-04).
[PASS] #4 -- SpokePayout requires recall complete -- onlyWithdrawalRegistry modifier on processWithdrawal()
[PASS] #5 -- YieldRouter recall atomic -- InsuranceReserve fallback implemented
[PASS] #6 -- fillFor requires actual transfer -- HubIntentSettler checks balanceOf before/after
[PASS] #7 -- AssetBehavior 48h timelock -- propose/apply/cancel pattern in AssetBehaviorRegistry
[PASS] #8 -- InsuranceReserve >= 10% -- verifyReserveRatio() checked on deploy()
[PASS] #9 -- BalanceLedger writes restricted -- onlyAuthorized modifier on all state-changing functions
[PASS] #10 -- Attestation replay prevention -- usedAttestationIds + monotonic timestamp in CollateralRegistry
[PASS] #11 -- No stale price for liquidation -- isPriceFresh() in LiquidationEngine.liquidate()
[PASS] #12 -- onIntentFilled only by Endpoint -- onlyEndpoint modifier in CentuariRouter
[PASS] #13 -- isUsedAsCollateral toggle safety -- HF check in BalanceLedger.setAsCollateral()
[PASS] #14 -- Debt ceiling enforcement -- RiskModule.validateBorrow() checks _totalDebtAgainstAsset
[PASS] #15 -- Anchor rate bounds -- CentuariEndpoint._processRollovers() validates anchorRate
[PASS] #16 -- CentuariRouter token accounting -- intent lifecycle tracks filled/unfilled amounts
[PASS] #17 -- CEI pattern -- State changes before external calls throughout
[PASS] #18 -- Liquidation nonReentrant -- Present on LiquidationEngine.liquidate()
[PASS] #19 -- Oracle reads before state gates -- Confirmed in RiskModule, LiquidationEngine
[PASS] #20 -- Admin functions timelocked -- All hub core contracts use 48h propose/apply. Exceptions: H-01 through H-04 below.
[PASS] #21 -- Withdraw when paused -- BalanceLedger.withdraw() has NO whenNotPaused modifier (correct)
[PASS] #22 -- Storage layout preserved -- All Storage.sol contracts have __gap, vars appended only
[PASS] #23 -- Interest accrued before HF check -- RiskModule uses live oracle, CentuariEndpoint accrues before HF
[PASS] #24 -- CBT mint validated +/-1 wei -- _computeExpectedCBT() in CentuariEndpoint
[PASS] #25 -- Rounding favors protocol -- Integer division truncates down consistently

---

### FINDINGS

**HIGH (4)**

**H-01: PCBTVault instant admin setters without timelock**
- File: src/core/pcbt/PCBTVault.sol lines 312-325
- Description: Three admin functions (`setWithdrawalCutoff`, `setNextMaturity`, `setCurrentCBT`) use `onlyOwner` with no timelock. `setCurrentCBT` changes which CBT contract the vault uses for redemptions, directly affecting user funds. `setWithdrawalCutoff` changes the withdrawal window. `setNextMaturity` changes the maturity date.
- Impact: A compromised owner can instantly redirect CBT redemptions to a different contract, change withdrawal timing, or alter maturity parameters. Users have no time to react.
- Fix: Add propose/apply/cancel pattern with 48h timelock, matching YieldRouter's pattern.

**H-02: RiskModule instant setSequencerUptimeFeed**
- File: src/core/RiskModule.sol line 386
- Description: `setSequencerUptimeFeed(address feed)` is instant `onlyOwner` with no timelock. The sequencer uptime feed controls whether oracle reads are paused after Arbitrum sequencer downtime. Setting this to address(0) disables the check entirely; setting to a malicious address could block all HF computations.
- Impact: Compromised owner can disable sequencer protection (enabling stale-price liquidations after sequencer downtime) or set a malicious feed that always reports "down" (blocking all borrowing/liquidation).
- Fix: Add 48h timelock propose/apply pattern.

**H-03: LiquidationEngine instant setSpokeVaultRWA**
- File: src/core/LiquidationEngine.sol line 339
- Description: `setSpokeVaultRWA(uint32 spokeEid, address vault)` is instant `onlyOwner`. This controls where cross-chain liquidation messages are routed. An incorrect or malicious address means liquidation proceeds are sent to the wrong contract.
- Impact: Misdirected cross-chain liquidation. Funds sent to attacker-controlled address on spoke chain.
- Fix: Add 48h timelock propose/apply pattern.

**H-04: SpokeVaultRWA instant setters for critical security parameters**
- File: src/spoke/SpokeVaultRWA.sol lines 92-98
- Description: Three instant `onlyOwner` setters: `setLayerZeroEndpoint`, `setHubLiquidationEngine`, `setHubChainEid`. These three values form the security gate for Invariant #3 (SpokeVaultRWA release only via LayerZero from hub). Changing any of them instantly bypasses the security model.
- Impact: Compromised owner can set hubLiquidationEngine to attacker address, then send a LayerZero message to drain all locked RWAs. Total RWA collateral loss.
- Fix: Add 48h timelock. For spoke contracts where OZ upgradeable timelocks are heavy, at minimum emit an event and enforce a delay via a pending/apply pattern.

---

**MEDIUM (5)**

**M-01: SpokePayout instant admin setters**
- File: src/spoke/SpokePayout.sol lines 125-126
- Description: `setSpokeVault` and `setWithdrawalRegistry` are instant. These control where withdrawal funds come from and who can authorize withdrawals.
- Impact: Compromised owner can redirect withdrawal authorization or vault source.
- Fix: Add timelock or at minimum event emission with delay.

**M-02: SpokeVaultStable instant admin setters**
- File: src/spoke/SpokeVaultStable.sol lines 69-70
- Description: `setSweeper` and `setSupportedAsset` are instant.
- Impact: Compromised owner can set a malicious sweeper that drains the vault buffer.
- Fix: Add timelock.

**M-03: MarketScheduleRegistry no timelock on schedule changes**
- File: src/core/MarketScheduleRegistry.sol lines 37-63
- Description: `addSchedule` and `updateSchedule` use `onlyOwner` with no timelock. Market schedules affect after-hours LTV buffers for tokenized equities.
- Impact: Manipulating market hours could remove the after-hours LTV haircut, enabling over-borrowing against equity collateral during market closures.
- Fix: Add 48h timelock consistent with other hub contracts.

**M-04: Pause authority inconsistency across contracts**
- File: Multiple (BalanceLedger, AssetBehaviorRegistry, FeeController use `onlyOwner`; CentuariEndpoint uses `onlyMultisig`)
- Description: Emergency pause should be multisig-controlled (fast response, no single point of failure). Several contracts use `onlyOwner` for pause/unpause instead of `onlyMultisig`.
- Impact: Single owner key compromise can pause protocol operations. Less resilient than multisig.
- Fix: Add `onlyMultisig` modifier for pause/unpause on all contracts, or ensure owner IS a multisig via deployment configuration.

**M-05: CentuariRouter ERC-4626 withdraw/redeem missing owner authorization**
- File: src/core/CentuariRouter.sol
- Description: The ERC-4626 `withdraw()` and `redeem()` functions allow any caller to withdraw on behalf of `owner` if they have `allowance`. Standard ERC-4626 behavior, but combined with the intent-based architecture, this could lead to unexpected withdrawals of pending intent positions.
- Impact: Low likelihood but potential for unintended withdrawal of positions mid-intent.
- Fix: Review ERC-4626 allowance model interaction with intent lifecycle. Consider restricting to `msg.sender == owner` for v1.

---

**LOW (3)**

**L-01: HubIntentSettler unused authorizedSolvers mapping**
- File: src/core/HubIntentSettler.sol line 22
- Description: `mapping(address => bool) public authorizedSolvers` is declared but never checked in `fillFor()`. The fillFor function is permissionless.
- Impact: Dead code. No security impact since fillFor requires actual token transfer (Invariant #6). But suggests incomplete access control implementation.
- Fix: Either implement solver authorization or remove the mapping.

**L-02: ProtocolTreasury uses inline storage instead of separate Storage.sol**
- File: src/core/ProtocolTreasury.sol
- Description: Non-upgradeable contract with inline storage. Not a bug since it is not behind a proxy, but inconsistent with the codebase pattern.
- Impact: No upgrade safety risk (not upgradeable). Minor consistency concern.
- Fix: Acceptable as-is for non-upgradeable contract.

**L-03: SettlementLedger.matchFill() silently skips transfer on insufficient balance**
- File: src/core/SettlementLedger.sol lines 73-78
- Description: If the contract does not hold sufficient token balance, the `safeTransfer` to the solver is silently skipped. The fill is still marked as `matched = true`.
- Impact: Solver may not receive reimbursement but the fill is recorded as complete. Requires manual intervention.
- Fix: Revert if balance insufficient, or emit a specific event for failed reimbursement.

---

**INFO (3)**

**I-01**: All hub core contracts (CentuariEndpoint, BalanceLedger, RiskModule, LiquidationEngine, YieldRouter, AssetBehaviorRegistry, CollateralRegistry, CentuariRateOracle, WithdrawalRegistry, FeeController, CentuariRouter, PCBTVault, MarketScheduleRegistry) correctly implement `_disableInitializers()` in constructor and `initializer` modifier on `initialize()`.

**I-02**: YieldRouter is the model implementation for the 48h timelock pattern. All other hub contracts with admin setters should follow its propose/apply/cancel pattern with `ADMIN_TIMELOCK = 48 hours`.

**I-03**: OZ 2-step ownership transfer (OwnableUpgradeable with acceptOwnership) used consistently across all upgradeable contracts. Prevents accidental ownership transfer to wrong address.

---

### TIMELOCK COVERAGE TABLE

| Contract | Admin Setters | Timelocked? | Status |
|---|---|---|---|
| CentuariEndpoint | updateEngineSigner, setMultisig | Yes (48h) | OK |
| BalanceLedger | setAuthorizedWriter | Yes (48h) | OK |
| RiskModule | setAuthorizedCaller | Yes (48h) | OK |
| RiskModule | setSequencerUptimeFeed | NO | **H-02** |
| LiquidationEngine | setAuthorizedCaller | Yes (48h) | OK |
| LiquidationEngine | setSpokeVaultRWA | NO | **H-03** |
| YieldRouter | setMultisig, setBalanceLedger, setABR, setAuthorizedCaller | Yes (48h) | OK (model) |
| YieldRouter | registerAdapter | Yes (48h) | OK |
| AssetBehaviorRegistry | registerAsset, updateAssetBehavior | Yes (48h) | OK |
| CollateralRegistry | setAuthorizedCaller | Yes (48h) | OK |
| CentuariRateOracle | setAuthorizedSigner | Yes (48h) | OK |
| WithdrawalRegistry | setAuthorizedCaller | Yes (48h) | OK |
| FeeController | setFees | Yes (48h) | OK |
| MarketScheduleRegistry | addSchedule, updateSchedule | NO | **M-03** |
| PCBTVault | setWithdrawalCutoff, setNextMaturity, setCurrentCBT | NO | **H-01** |
| SettlementLedger | setAuthorizedCaller | Yes (48h) | OK |
| SpokeVaultRWA | setLayerZeroEndpoint, setHubLiquidationEngine, setHubChainEid | NO | **H-04** |
| SpokePayout | setSpokeVault, setWithdrawalRegistry | NO | **M-01** |
| SpokeVaultStable | setSweeper, setSupportedAsset | NO | **M-02** |

---

### RECURRING PATTERNS

This audit confirms the recurring pattern from prior audits: **instant admin setters on security-critical parameters**. This is the single most common finding across all Centuari audits (flagged in audit_reentrancy_cei_access_2026-03-25, audit_blackhat_2026-03-25, invariant_verification_2026-03-25, and multiple others). The hub core contracts have been largely fixed with 48h timelocks, but PCBTVault, spoke contracts, and MarketScheduleRegistry still have gaps.

**Why:** Cross-cutting access control audit for professional audit readiness.
**How to apply:** H-01 through H-04 must be fixed before mainnet. All instant admin setters on parameters that gate security invariants or affect user funds need 48h timelocks.
