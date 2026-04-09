---
name: Balance/Yield/Treasury Deep Audit 2026-04-01
description: Mainnet-grade audit of BalanceLedger, YieldRouter, Treasury — deposit/withdrawal/yield flows. 1 CRITICAL (yield underflow locks funds), 2 HIGH, 5 MEDIUM.
type: project
---

## Audit: BalanceLedger + YieldRouter + Treasury (2026-04-01)

**Files**: BalanceLedger.sol, BalanceLedgerStorage.sol, YieldRouter.sol, YieldRouterStorage.sol, Treasury.sol, all related interfaces.

**VERDICT**: REQUEST CHANGES

### Critical Findings
- **C-01**: YieldRouter recall underflow — all 4 recall paths do `_adapterDeployed -= recalled` where `recalled` includes yield, causing underflow revert. Funds permanently locked once any adapter earns yield. Affects lines 135-136, 165-166, 186-188, 261-263.

### High Findings
- **H-01**: YieldRouter.deploy() attributes shares to msg.sender (authorized caller) not the actual user. Makes recall impossible.
- **H-02**: BalanceLedger.withdraw() HF check is dead code — HF depends on _collateral positions, not available balance. The "H-01 FIX" provides false sense of security.

### Medium Findings
- **M-01**: Treasury.setOperator() no timelock — instant admin setter for withdrawal authority.
- **M-02**: YieldRouter.rebalance() mixes global _adapterDeployed with per-user shares — wrong scope.
- **M-03**: reduceCollateral() ignores sourceChainId — wrong cross-chain collateral reduced.
- **M-04**: Unbounded _collateral array — DoS vector for liquidation.
- **M-05**: Treasury.deposit() no fee-on-transfer protection.

### Recurring Patterns Confirmed
- Pattern #2 (accounting without transfer): transferOut() sends tokens without balance deduction
- Pattern #4 (missing timelocks): Treasury.setOperator()
- Pattern #7 (shared token pool): BalanceLedger pools deposits + CBT backing

**Why:** YieldRouter yield accounting is fundamentally broken — the deployed/recalled tracking assumes adapters return exactly what was deposited, but the entire point of yield adapters is to return MORE.

**How to apply:** Any future yield-related code must track "original deposited amount" separately from "current value including yield". The delta is yield, not a bug.
