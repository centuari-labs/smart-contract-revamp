# Architecture Map - Centuari Hub Core (Cross-chain Excluded)

audit_date: 2026-06-05
source_commit: 8a9451194e27df4abaced439d1c49e119a9b2456

## Component overview

```
                  ┌─────────────────────────────┐
                  │  Operator (backend)         │
                  │  - off-chain matcher        │
                  │  - permissioned settler     │
                  │  - permissioned repayer     │
                  └─────────────────────────────┘
                              │
                  ┌───────────▼───────────────┐
                  │  Settlement (upgradeable) │  onlyOperator
                  │  matchId dedup            │
                  └───────────┬───────────────┘
                              │ Centuari.settleMatch
                  ┌───────────▼───────────────┐
                  │  Centuari (upgradeable)   │
                  │  - day-count interest     │   _operator -> repay
                  │  - debt accounting        │   _liquidationEngine -> liquidationRepay
                  │  - lender/borrower book   │   onlyOwner -> rotate keys
                  │  - withdrawLendPosition   │   anyone (after maturity)
                  └─┬────────────────────────┬┘
                    │ credit/debit /         │ mint/burn
                    │ markCollateral         │
                    ▼                        ▼
            ┌──────────────────┐  ┌────────────────────────┐
            │ BalanceLedger    │  │ CentuariBondERC20 *N   │
            │  - available     │  │  - 1:1 redeemable      │
            │  - inOrders=0    │  │  - mintable by Centuari│
            │  - inYieldRouter=0│  │  - factory CREATE2     │
            │  - usedAsCollat  │  └────────────────────────┘
            │  - flaggedAt     │
            └─┬────────────────┘
              │ writer-allowed (set by owner via 48h timelock)
              ▼
        ┌────────────────────────────┐
        │ CollateralManager          │ operator + direct caller
        │  - flag / unflag           │ 24h _flagLock
        │  - canUnflag gate via RM   │
        └────────────────────────────┘
              │
              ▼
        ┌────────────────────────────┐
        │ RiskModule (upgradeable)   │ view-only, never reverts
        │  - canWithdraw             │ fail-closed on stale
        │  - canUnflag               │
        │  - isLiquidatable          │
        │  - healthFactor            │
        └─┬──────────────────────────┘
          │ tryGetUsdValue
          ▼
    ┌────────────────────────────────────────────┐
    │ OracleRouter (upgradeable, IPriceOracle)   │
    │  - per-asset _feeds[asset]                  │
    │  - per-asset _maxStaleness[asset]           │
    └─┬───────────────────────────────────────────┘
      │ feed.latestPriceUsd()
      ├─────────────┬───────────────┐
      ▼             ▼               ▼
   PushOracle    ChainlinkPriceFeed (dormant on Arb-Sepolia)
   (operator)    (wraps AggregatorV3 + sequencer feed)

   ┌────────────────────────────────────────┐
   │ LiquidationEngine (upgradeable)        │ permissionless
   │  - trigger: matured OR HF<1            │
   │  - liquidator funds repay from BL      │
   │  - bonus on collateral seizure         │
   │  - auto-unflag at full drain           │
   │  - calls Centuari.liquidationRepay     │
   └────────────────────────────────────────┘
```

## Key data flows

### A. Settlement flow (operator-driven)

1. Off-chain matcher pairs lender/borrower orders.
2. Operator calls `Settlement.settleMatches(matches[])` (batch) or `settleMatch(m)` (single).
3. Settlement validates non-zero fields, dedupes via `_settledMatches[matchId]`.
4. Settlement calls `Centuari.settleMatch(marketId, lender, borrower, loanToken, matchedAmount, rate, maturity, borrowerIsTaker, lenderFee, borrowerFee, makerFee, takerFee, collateralAssets[])`.
5. Centuari:
   - Asserts `maturity > block.timestamp`, `matchedAmount > 0`.
   - Persists `_marketLoanToken[marketId] = loanToken` if unset.
   - Resolves bond token via `CentuariBondERC20Factory.getOrCreate(loanToken, maturity)`.
   - Records lender's CBT position: `cbt = principal + day_count_interest`.
   - Records borrower's debt: `debt = principal + day_count_interest`.
   - If first time for borrower in this market, asserts `_borrowerMarkets[borrower].length() < MAX_DEBT_MARKETS (64)` and adds.
   - BalanceLedger: debit lender (`matchedAmount + totalLenderFee`), credit borrower (`matchedAmount`), debit borrower fees, credit fee collector all fees.
   - For each `collateralAssets[i]`, calls `BalanceLedger.markCollateral(borrower, collateralAssets[i])` (bounded by MAX_FLAGGED_ASSETS=32).
   - Mints `cbt` CBT to Centuari custody (Centuari holds bond tokens).

### B. Repay flow (operator-driven)

`Centuari.repay(marketId, borrower, loanToken, amount)`:
- `amount` capped at `_borrowDebt[marketId][borrower]`.
- Decrements debt, removes from `_borrowerMarkets` set if zeroed.
- Debits borrower's BalanceLedger.available.
- Does NOT auto-unflag collateral; user explicitly unflags via CollateralManager.

### C. Lender withdraw flow (anyone, after maturity)

`Centuari.withdrawLendPosition(marketId, loanToken, maturity, cbtAmount)`:
- `block.timestamp >= maturity` required.
- Burns `cbtAmount` from Centuari's CBT custody.
- Decrements `_lendPositionCbtAmount[marketId][msg.sender]` and `_marketTotalCbt[marketId]`.
- Credits `msg.sender` with `cbtAmount` loan token in BalanceLedger.

### D. Collateral flag flow

- Set at settlement via `Settlement → Centuari.settleMatch → BalanceLedger.markCollateral`.
- Set mid-life via `CollateralManager.flagFor(user, asset)` (operator) or `flag(asset)` (direct).
- Unset via `CollateralManager.unflagFor(user, asset)` / `unflag(asset)`:
  - Requires `flaggedAt > 0`.
  - Requires `block.timestamp >= flaggedAt + _flagLock` (default 24h).
  - Requires `IRiskModule(_riskModule).canUnflag(user, asset)` returns true.
- Auto-unset on full collateral drain during liquidation.

### E. Liquidation flow (permissionless)

`LiquidationEngine.liquidate(borrower, loanToken, maturity, collateralAsset, repayLoanAmount, minCollateralOut)`:
1. Resolve `marketId = Centuari.getMarketId(loanToken, maturity)`.
2. Read `debt = Centuari.getBorrowPosition(marketId, borrower)`.
3. Trigger: `viaMaturity = block.timestamp >= maturity` OR `RiskModule.isLiquidatable(borrower)`.
4. Close factor: `repaid = min(repayLoanAmount, debt * closeFactor / BPS)`.
5. Assert `usedAsCollateral(borrower, collateralAsset)`.
6. Compute `repayUsd` (oracle), `seizeUsd = repayUsd * (1 + bonusBps / BPS)`, `collateralSeized = _usdToBaseUnits(collateralAsset, seizeUsd)`.
7. Bad-debt cap: if `collateralSeized > availColl`, cap to `availColl` and back out `repaid` from `cappedUsd / (1 + bonus)`.
8. Slippage: `collateralSeized >= minCollateralOut`.
9. `Centuari.liquidationRepay(marketId, borrower, loanToken, liquidator=msg.sender, repaid)` debits liquidator's loan token.
10. `BalanceLedger.debit(borrower, collateralAsset, collateralSeized)` and `credit(msg.sender, collateralAsset, collateralSeized)`.
11. If `availColl - collateralSeized == 0`, `BalanceLedger.unmarkCollateral(borrower, collateralAsset)`.

### F. Health-factor math (RiskModule)

For each loan token in `Centuari.getBorrowerDebts(user)`:
- `debtUsd_token = OracleRouter.tryGetUsdValue(loanToken, debt_token)`.
- Fail-closed if any token is unpriced.

For each asset in `BalanceLedger.flaggedAssetsOf(user)`:
- Skip the acted asset if `removeEntirely == true`.
- Adjust amount by `withdrawAmount` for the acted asset.
- `cVal = OracleRouter.tryGetUsdValue(asset, amount)`.
- `ltvWeighted += cVal * ltvBps[asset] / BPS`.
- `collateralUsd += cVal`.
- `maxBufferBps = max(_bufferBps[asset] || _defaultBufferBps)`.

If `collateralUsd <= debtUsd` return `(hf=0, priced=true, hasDebt=true)`.

Else:
- `hf = (collateralUsd - debtUsd) * ltvWeighted / collateralUsd / debtUsd` (1e18).
- Note: `hf == (1 - debtUsd/collateralUsd) * weightedLTV`, NOT the standard `Σ cVal*ltv / debt`. The protocol's HF is strictly less than `weightedLTV` and approaches it asymptotically. This makes the gate more conservative than industry-standard.
- `canWithdraw / canUnflag` pass iff `hf >= 1e18 + maxBufferBps * 1e18 / 1e4`.
- `isLiquidatable` triggers iff `hf < 1e18` (no buffer).

## Trust assumptions

| Role | Who | Powers |
|------|-----|--------|
| Owner (Centuari, Settlement, CollateralManager, RiskModule, OracleRouter, LiquidationEngine, BalanceLedger) | TimelockController (24h ops, 48h upgrade) | rotate operator, pauser, RiskModule, oracle, LTV, buffer, bonus, close factor, BalanceLedger writers |
| ProxyAdmin | Separate timelock | upgrade implementation |
| Operator (Settlement, Centuari, CollateralManager) | Backend hot key | submit settlements, call repay, flagFor/unflagFor, seedBorrowerMarkets |
| Pauser | Multisig or hot key | pause/unpause all six pausable contracts |
| PushOracle operator | Backend hot key | push prices (bounded by [minPrice, maxPrice] and per-update deviation) |
| PushOracle owner | Multisig | rotate operator, set price bounds, set deviation cap |
| BalanceLedger writers | Authorized contracts | credit/debit/markCollateral/unmarkCollateral |
| Liquidator | Anyone | call `LiquidationEngine.liquidate` |
| Lender / Borrower | Anyone | submit orders off-chain, withdraw after maturity, flag/unflag self |

## Upgrade architecture

- Each upgradeable contract has its own `*Storage` abstract with `__gap`.
- ERC1967 Transparent Proxy pattern.
- `_disableInitializers()` in constructors prevents implementation-side init.
- `initialize()` is `external initializer`.
- Storage layout snapshots in `test/snapshots/` enforced by CI (`bin/check-storage-layout.sh`).
- ReentrancyGuard uses ERC7201 namespaced storage (collision-safe).

## Notable design choices

1. **No on-chain "balance lock" in Phase 1**: lender's balance can be withdrawn before settlement (no `inOrders` lock). If lender withdraws between order signing and settlement, the operator's batch reverts on `InsufficientBalance` — only the operator is griefable, not the protocol.
2. **MarketId is operator-provided**, not derived from (loanToken, maturity). Settlement does not assert `marketId == keccak256(loanToken, maturity)`. Centuari's `getBorrowerDebts` joins `_borrowerMarkets` to `_marketLoanToken[mid]`. If operator uses a non-canonical marketId, accounting is at that non-canonical key; bond token is at the canonical key. Operator is trusted.
3. **HF formula is conservative**: `(collateralUsd - debtUsd) * weightedLTV / debtUsd`, NOT the industry-standard `Σ cVal * ltv / debt`. Worst-case HF ceiling is `weightedLTV` (≤ 1.0 for LTVs ≤ 100%). Means the same collateral supports less debt than usual.
4. **Day-count interest convention**: `days_ = max(0, rawDays - 1)` where `rawDays = floor((maturity - start) / 1 days)`. A 1-day maturity earns 0 interest; a 30-day maturity earns 29 days; etc. Documented as "start+1 = day 1, maturity-1 = last day".
5. **CBT tokens never leave Centuari custody**: bonds are minted to and burned from `address(this)`. The CBT ERC20 is transferable but no protocol flow ever transfers it out. Lender's claim is tracked via `_lendPositionCbtAmount` mapping.
6. **Repay is operator-gated**: borrowers cannot directly repay; they depend on the operator. Escape hatch: after maturity, anyone (including borrower) can call `LiquidationEngine.liquidate` to effectively self-repay.
7. **Auto-flag at settlement is opt-in via `collateralAssets[]`**: the borrower's off-chain order specifies which assets to flag; the operator relays. There is no implicit "auto-flag any deposit".
8. **Fail-closed everywhere on oracle**: stale or missing prices return `(0, false)` from `tryGetUsdValue` → RiskModule returns false on any check involving that asset → withdraw / unflag denied, liquidation denied. Protocol halts on stale oracle.
9. **Separate pauser per contract**: each pausable contract has its own `_pauser` slot. Owner can rotate. Pauser has no timelock (fast emergency).
