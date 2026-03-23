---
name: security-review
description: >
  Invoke before any PR merge touching Solidity. Also invoke when
  exploring a contract for the first time, when implementing a new
  financial mechanism, or when something in the code feels wrong but
  you cannot name why. This skill is the first line of defense.
allowed-tools: Read, Grep, Bash, Glob
---

# Security Review Checklist for Centuari Contracts

Run this checklist against every contract under review. Report each area as **CLEAR** or **FLAGGED** with the specific code location.

## 1. Checks-Effects-Interactions (CEI)

Find every external call in the contract:
```bash
# Find all external calls
grep -n '\.call\|\.transfer\|\.send\|safeTransfer\|\.staticcall' src/core/TARGET.sol
# Find interface calls (other contracts)
grep -n 'I[A-Z].*(' src/core/TARGET.sol
```

For each external call:
- [ ] All storage writes happen BEFORE the call
- [ ] No storage reads AFTER the call depend on pre-call state
- [ ] The function has `nonReentrant` if it moves tokens or changes positions

Report: `[CLEAR/FLAGGED] CEI — external call at LINE, state change at LINE`

## 2. Reentrancy Guard Coverage

```bash
grep -n 'nonReentrant\|ReentrancyGuard' src/core/TARGET.sol
grep -n 'external\|public' src/core/TARGET.sol
```

For every `external`/`public` function that:
- Transfers tokens (safeTransfer, credit, debit)
- Calls another contract (interface call, low-level call)
- Changes position state (collateral, debt, balance)

Verify: `nonReentrant` modifier is present.

Report: `[CLEAR/FLAGGED] Reentrancy — [function] at LINE missing nonReentrant`

## 3. Oracle Freshness

```bash
grep -n 'latestRoundData\|priceFeed\|usdValue\|getAssetPrice' src/core/TARGET.sol
```

For every oracle price read:
- [ ] Staleness check exists: `block.timestamp - updatedAt <= maxStaleness`
- [ ] Revert on stale (not silent fallback)
- [ ] `answer > 0` check (reject negative/zero prices)
- [ ] Price feed address is from trusted registry (AssetBehaviorRegistry)

Report: `[CLEAR/FLAGGED] Oracle — price read at LINE, staleness check at LINE`

## 4. Interest Accrual Ordering

```bash
grep -n 'getHealthFactor\|healthFactor\|_getWeightedCollateral\|validateBorrow' src/core/TARGET.sol
```

For every health factor computation or borrow validation:
- [ ] Interest/debt is current before the HF read
- [ ] No path allows HF check on stale debt data

Report: `[CLEAR/FLAGGED] Interest ordering — HF check at LINE, debt state at LINE`

## 5. Liquidation Bounds

If the contract involves liquidation:
- [ ] Max liquidation amount enforced (50% of debt)
- [ ] Post-liquidation HF cannot exceed 1.0 (no over-liquidation)
- [ ] Grace period enforced on-chain (block.timestamp vs deadline)
- [ ] Oracle freshness checked before seizure computation
- [ ] Bonus computation correct: `debtWithBonus = debt * (10000 + bonus) / 10000`

Report: `[CLEAR/FLAGGED] Liquidation — bounds check at LINE`

## 6. Collateral Decimal Normalization

```bash
grep -n 'decimals\|10 \*\*\|1e18\|1e6' src/core/TARGET.sol
```

For every place multiple collateral token amounts are combined:
- [ ] All values normalized to same decimal base (18 decimals)
- [ ] Chainlink feed decimals accounted for: `price * 10^(18-feedDecimals)`
- [ ] No raw token amounts compared across different decimal tokens

Report: `[CLEAR/FLAGGED] Decimals — normalization at LINE`

## 7. Access Control Audit

```bash
grep -n 'external\|public' src/core/TARGET.sol | grep -v 'view\|pure'
```

For every state-changing external/public function:
- [ ] Has appropriate modifier: `onlyOwner`, `onlyAuthorized`, `onlyOperator`, `onlyMultisig`, `onlyCentuari`, etc.
- [ ] Functions that move funds NEVER lack access control
- [ ] Timelock on functions that change critical parameters (LTV, rates, asset listings)

Report: `[CLEAR/FLAGGED] Access — [function] at LINE has [modifier/NONE]`

## 8. Unchecked Blocks

```bash
grep -n -A3 'unchecked' src/core/TARGET.sol
```

For every `unchecked {}` block:
- [ ] Comment explaining the invariant that prevents overflow/underflow
- [ ] The invariant is enforced by a preceding check (e.g., `if (a < b) revert`)
- [ ] Only loop counters (i++) are unchecked without explicit justification

Report: `[CLEAR/FLAGGED] Unchecked — block at LINE, invariant: [description]`

## 9. Storage Layout (Upgradeable Contracts)

```bash
grep -n '__gap\|private\|internal' src/core/TARGETStorage.sol
```

- [ ] `*Storage.sol` exists with all state variables
- [ ] `__gap` array present at end of storage
- [ ] Variables only appended, never inserted between existing
- [ ] `_disableInitializers()` in constructor
- [ ] `initializer` modifier on `initialize()`
- [ ] No shadowed variable names between storage and implementation

Report: `[CLEAR/FLAGGED] Storage — gap size: [N], layout: [OK/ISSUE]`

## 10. Static Analysis

If slither is configured:
```bash
slither src/core/TARGET.sol --filter-paths "lib/|test/|script/" 2>&1 | head -50
```

Priority detector classes for Centuari:
- `reentrancy-eth` — reentrancy with ETH transfer
- `reentrancy-no-eth` — reentrancy without ETH
- `arbitrary-send-erc20` — unauthorized token transfers
- `unchecked-transfer` — ERC20 return value not checked
- `divide-before-multiply` — precision loss
- `locked-ether` — ETH stuck in contract
- `uninitialized-state` — upgradeable init not called

## Output Format

```
CONTRACT: [name]
FILE: [path]

1. CEI:              [CLEAR/FLAGGED] — [details]
2. Reentrancy:       [CLEAR/FLAGGED] — [details]
3. Oracle:           [CLEAR/FLAGGED] — [details]
4. Interest Order:   [CLEAR/FLAGGED] — [details]
5. Liquidation:      [CLEAR/FLAGGED] — [details or N/A]
6. Decimals:         [CLEAR/FLAGGED] — [details]
7. Access Control:   [CLEAR/FLAGGED] — [details]
8. Unchecked:        [CLEAR/FLAGGED] — [details]
9. Storage Layout:   [CLEAR/FLAGGED] — [details]
10. Static Analysis: [CLEAR/FLAGGED/NOT CONFIGURED]

OVERALL: [PASS / NEEDS REVIEW]
FLAGGED ITEMS: [count]
```
