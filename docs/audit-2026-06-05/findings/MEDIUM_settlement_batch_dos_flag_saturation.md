# [MEDIUM] Settlement batch DoS via attacker-saturated `_flaggedAssets` set

## Target
- `src/core/collateral/CollateralManager.sol:114-116` (permissionless `flag(asset)`).
- `src/core/balance-ledger/BalanceLedger.sol:140-152` (MAX_FLAGGED_ASSETS=32 cap).
- `src/core/centuari/Centuari.sol:185-187` (settleMatch loop calling `markCollateral` per `collateralAssets[i]`).
- `src/core/settlement/Settlement.sol:76-100` (`settleMatches` batch atomicity).

## Summary
`CollateralManager.flag(asset)` is permissionless and does not require the caller to hold any balance of `asset`. The flag counts toward `BalanceLedger`'s 32-asset cap. An attacker creates a fresh address, fills its `_flaggedAssets` set to 32 with arbitrary tokens, then submits an off-chain borrow order containing one *additional* asset in `collateralAssets`. When the operator includes that match in a batch, Centuari's settle loop calls `markCollateral` on the 33rd asset, reverts `TooManyFlaggedAssets`, and the entire `Settlement.settleMatches` batch reverts. Operator pays gas; nothing settles.

## Detail

```solidity
// CollateralManager.sol:114-116
function flag(address asset) external nonReentrant {
    _flag(msg.sender, asset); // _flag → BalanceLedger.markCollateral, no balance check
}
```

```solidity
// BalanceLedger.sol:140-148 (inside _setCollateralFlag)
if (used) {
    if (_usedAsCollateral[user][asset]) return;
    if (_flaggedAssets[user].length() >= MAX_FLAGGED_ASSETS) revert TooManyFlaggedAssets();
    ...
}
```

```solidity
// Centuari.sol:185-187 (inside settleMatch)
for (uint256 i = 0; i < collateralAssets.length; ++i) {
    IBalanceLedger(_balanceLedger).markCollateral(borrower, collateralAssets[i]);
}
```

```solidity
// Settlement.sol:85-97 — single revert nukes the whole batch
for (uint256 i; i < matchCount;) {
    MatchData calldata matchData = matches[i];
    _processMatch(matchData, centuariAddr);  // revert here → whole batch reverts
    totalVolume += matchData.matchedAmount;
    unchecked { ++i; }
}
```

## Impact
Operator-side gas / throughput griefing:
- One attacker can repeatedly halt the operator's settlement batches.
- Each attack costs the attacker ~32 cheap `flag(asset)` txs (a few hundred-thousand gas each) per fresh victim address. The operator's batch-reverted gas is far larger (5-15M gas for a typical 50-match batch).
- The operator's natural mitigation (pre-filter borrowers by `_flaggedAssets.length() + collateralAssets.length()`) is defeated by the race: the attacker flags during the operator's read-build-submit window.

No fund loss. No protocol insolvency. Pure operator-throughput attack.

## Recommended Fix
Two complementary options:

**Option A — caller-side balance gating (preferred):**
```solidity
function flag(address asset) external nonReentrant {
    if (IBalanceLedger(_balanceLedger).available(msg.sender, asset) == 0) revert NoBalanceToFlag();
    _flag(msg.sender, asset);
}
```
This makes `flag()` cost an attacker the price of at least 1 wei of each `asset` they want to flag. The 32-asset attack becomes uneconomical for non-trivial token sets.

**Option B — per-match isolation in Settlement (defense-in-depth):**
Move `_processMatch` into a `try/catch` so a single failing match drops only itself, not the batch:
```solidity
for (uint256 i; i < matchCount;) {
    try this.tryProcessMatch(matches[i], centuariAddr) {
        totalVolume += matches[i].matchedAmount;
    } catch (bytes memory /*reason*/) {
        emit MatchFailed(matches[i].matchId);
    }
    unchecked { ++i; }
}
```
(This requires extracting `_processMatch` to an external `tryProcessMatch` since `try/catch` only works on external calls.) Either option alone closes the attack; both together raise the bar substantially.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Medium |
| `confidence_0_100` | 75 |
| `single_strongest_reject` | "Operator can pre-filter and retry without the malicious match." — counter: the race window between read and on-chain landing breaks the pre-filter, and any sustained DoS pattern undermines settlement SLA. |
| `gate_failures` | none |
| `poc_status` | NOT_BUILT (concept verified by code path; trivial to write) |
