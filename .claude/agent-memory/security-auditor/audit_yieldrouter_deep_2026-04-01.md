---
name: YieldRouter Deep Architectural Audit (2026-04-01)
description: Deep audit of YieldRouter + 3 adapters focusing on per-user vs pooled design. 4 CRITICAL (deploy shares to msg.sender, token/share mismatch, underflow on recall, trapped yield), 3 HIGH (pause no recall, no cash buffer, broken rebalance), 1 MEDIUM (manual reserve). VERDICT: REQUEST CHANGES — contract non-functional.
type: project
---

## YieldRouter Deep Architectural Audit — 2026-04-01

### Files Audited
- `src/core/YieldRouter.sol` (491 lines)
- `src/core/YieldRouterStorage.sol` (83 lines)
- `src/interfaces/IYieldRouter.sol`, `src/interfaces/IYieldAdapter.sol`
- `src/adapters/AaveV3Adapter.sol`, `CompoundV3Adapter.sol`, `MorphoAdapter.sol`
- `src/core/BalanceLedger.sol` (471 lines)

### Findings Summary
- **4 CRITICAL**: C-01 deploy() shares to msg.sender not user (line 105), C-02 recallForOrder token/share mismatch (line 162), C-03 _adapterDeployed underflow on recall (lines 135/166/187), C-04 all 3 adapters trap yield permanently (_totalDeployed never updated)
- **3 HIGH**: H-01 pauseAdapter no recall (line 381), H-02 VAULT_RAW_MINIMUM_BPS never enforced, H-03 rebalance uses global state for per-user ops (line 209)
- **1 MEDIUM**: M-01 InsuranceReserve manual-only growth

### Core Architectural Assessment
Per-user share tracking model is architecturally correct for Phase 1 but needs:
1. Cap adapters at 5 for gas bounds
2. Add userTotalShares summary mapping
3. Batch deploy/recall for multiple users
4. Minimum deploy amount ($500) to prevent dust

**Why:** C-01 alone makes the entire YieldRouter non-functional — no user can ever recall deployed capital. All 4 CRITICALs must be fixed before any real capital can flow through the router.

**How to apply:** Any PR touching YieldRouter must verify: (1) deploy() takes user parameter, (2) share/token units are never mixed, (3) adapter _totalDeployed reflects actual position value, (4) recall subtraction cannot underflow.

### Recurring Patterns Confirmed
- #1: Accounting without token transfer (C-04 trapped yield)
- #4: Missing timelocks — N/A here (timelocks properly implemented)
- #6: Decimal/unit mismatch (C-02 token vs share units)
- NEW: msg.sender vs user parameter mismatch in authorized-caller patterns
