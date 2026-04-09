---
name: Cross-Chain & RWA Layer Architectural Audit (2026-04-02)
description: Focused audit of CollateralRegistry, BalanceLedger (collateral ops), WithdrawalRegistry, HubIntentSettler, SettlementLedger, SpokeVaultRWA, SpokePayout. 5 HIGH, 4 MEDIUM, 2 LOW, 2 INFO. Cross-chain collateral flow fundamentally broken.
type: project
---

## Cross-Chain & RWA Layer Architectural Audit — 2026-04-02

### Files Audited
- src/core/CollateralRegistry.sol (379 lines)
- src/core/BalanceLedger.sol (471 lines, collateral functions)
- src/core/WithdrawalRegistry.sol (196 lines)
- src/core/HubIntentSettler.sol (108 lines)
- src/core/SettlementLedger.sol (119 lines)
- src/spoke/SpokeVaultRWA.sol (116 lines)
- src/spoke/SpokePayout.sol (127 lines)
- src/core/LiquidationEngine.sol (cross-reference, lines 140-170)

### VERDICT: REQUEST CHANGES

### Findings Summary: 5 HIGH, 4 MEDIUM, 2 LOW, 2 INFO

### HIGH Findings

**H-01: BalanceLedger.sol:256** — `reduceCollateral()` ignores sourceChainId. Reduces first matching asset regardless of chain. Wrong cross-chain position debited during liquidation. **M-03 from prior audits CONFIRMED and still present.**

**H-02: BalanceLedger.sol:338** — `updateCollateralUsdValue()` ignores sourceChainId. Only first entry for an asset gets price updates. Other chain entries permanently stale. Incorrect HF computation.

**H-03: BalanceLedger.sol:455** — `getCollateralByAsset()` ignores sourceChainId. Returns wrong position to LiquidationEngine and other callers. Wrong collateral state checked during liquidation.

**H-04: SpokeVaultRWA.sol:54** — Attestation sent to `hubLiquidationEngine` instead of `hubCollateralRegistry`. Comment says "Reusing as hub target." LiquidationEngine has no attestation handler. Entire RWA attestation flow is non-functional.

**H-05: LiquidationEngine.sol:153** — `addCollateral()` for liquidator uses `block.chainid` (hub/Arbitrum) even when collateral is physically on a spoke chain. Creates phantom collateral position with wrong sourceChainId.

### MEDIUM Findings

**M-01: HubIntentSettler.sol:22,40** — `_authorizedSolvers` mapping declared and managed but never checked in `fillFor()`. Anyone can call fillFor(). Solver trust model not enforced.

**M-02: SettlementLedger.sol:48** — `register()` stores `asset: address(0)`. `matchFill()` line 73 checks `fill.asset != address(0)` which is always false. Solver reimbursement via safeTransfer never executes. HubIntentSettler calls `register()` instead of `registerWithAsset()`.

**M-03: SettlementLedger.sol:73-77** — `matchFill()` does not verify `bridgedAmount >= fill.amount`. Partial reimbursement marks fill as matched, preventing future claims. Solver permanently short-changed.

**M-04: SpokeVaultRWA.sol:92-98, SpokePayout.sol:125-126** — Instant admin setters without timelocks on spoke contracts. Hub contracts fixed; spoke contracts not. Compromised owner key can redirect LayerZero validation targets, draining all locked RWAs.

### LOW Findings

**L-01: SpokePayout.sol:91** — Unbounded `queuedRequestIds` loop in `processQueued()`. DoS if many withdrawals queue during buffer shortage.

**L-02: WithdrawalRegistry.sol:63** — PENDING state does not lock balance. Double-spend possible across multiple PENDING withdrawals.

### INFO Findings

**I-01: HubIntentSettler.sol:53** — Credits `amount` not `received`. Excess from rebasing tokens trapped.

**I-02: HubIntentSettler.sol, SettlementLedger.sol** — Non-upgradeable hub contracts (Ownable). Cannot upgrade in place if bugs found.

### Key Patterns

1. **sourceChainId systematic omission**: `addCollateral()` was fixed to include sourceChainId, but `reduceCollateral()`, `updateCollateralUsdValue()`, and `getCollateralByAsset()` were not. Classic incomplete fix propagation. This is the 5th audit flagging this pattern.

2. **Broken integration paths**: SpokeVaultRWA sends attestation to wrong contract. HubIntentSettler calls wrong SettlementLedger function. Both break entire subsystem flows.

3. **Spoke contracts missed in hub fix waves**: Hub contracts got timelocks; spoke contracts did not. Hub contracts got UUPS upgradeable; spoke contracts did not.

### Invariant Check (Cross-Chain Subset)
- [PASS] #3 — SpokeVaultRWA.lzReceive() validates srcEid + sender
- [PASS] #4 — WithdrawalRegistry state machine + SpokePayout stored authorization
- [PARTIAL] #6 — Token transfer verified, but solver authorization not enforced
- [PASS] #9 — BalanceLedger.onlyAuthorized on all writes
- [PASS] #10 — CollateralRegistry attestation replay prevention correct
