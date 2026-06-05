# Invariants - Centuari Hub Core

audit_date: 2026-06-05

Invariants below are framed as **hypotheses to attack**, not assertions.

## BalanceLedger

- B-1: `available + inOrders + inYieldRouter` of a user/asset always equals the same number before and after any non-balance-mutating call (settles, flag mutations).
- B-2: `_balances[u][a].available` only increases via `credit()` and decreases via `debit()`, both gated by `onlyAuthorizedWriter && whenNotPaused`.
- B-3: `available` never goes negative; `debit` reverts on underflow.
- B-4: `_usedAsCollateral[u][a] == true` iff `_flaggedAssets[u].contains(a)` iff `_flaggedAt[u][a] != 0`. Mutated together in `_setCollateralFlag`.
- B-5: `_flaggedAt[u][a]` is set on the *first* `false→true` transition and never refreshed by idempotent re-mark.
- B-6: `_flaggedAssets[u].length() <= MAX_FLAGGED_ASSETS (32)`.
- B-7: writers added only via 48h timelock OR via `forceAddWriter` (which requires `_forceWriterRegistrationEnabled` set at init).
- B-8: `removeAuthorizedWriter` is instant (no timelock) for emergency revocation.
- B-9: All mutators revert if `_paused`.

## Centuari

- C-1: `_marketTotalCbt[mid]` equals the sum of `_lendPositionCbtAmount[mid][lender]` over all lenders (no leakage).
- C-2: For each `(loanToken, maturity)` with a deployed bond token, `bondToken.balanceOf(centuari) == _marketTotalCbt[canonical_mid]` where `canonical_mid = keccak256(loanToken, maturity)` — IF settlements use canonical marketId. **Falsifiable**: operator can pass non-canonical marketId; accounting goes to non-canonical mid while bond token is at canonical, breaking the invariant. Operator is trusted.
- C-3: `_borrowerMarkets[u].contains(mid)` iff `_borrowDebt[mid][u] > 0` (post-settlement / post-repay; not necessarily mid-tx). Maintained by add-on-new-debt / remove-on-zero-debt in `settleMatch`, `repay`, `liquidationRepay`.
- C-4: `_borrowerMarkets[u].length() <= MAX_DEBT_MARKETS (64)` for any user.
- C-5: For every `mid` in `_borrowerMarkets[u]`, `_marketLoanToken[mid] != address(0)`. Maintained by setting `_marketLoanToken` before adding to set.
- C-6: `settleMatch` reverts iff `maturity <= block.timestamp`, `matchedAmount == 0`, lender == borrower (Settlement-side), or any debit/credit reverts (insufficient balance, etc.).
- C-7: `repay(amount)` caps at `debt`, so the borrower's debt never goes negative.
- C-8: `withdrawLendPosition` requires `block.timestamp >= maturity` AND `_lendPositionCbtAmount[mid][caller] >= cbtAmount` AND `_marketTotalCbt[mid] >= cbtAmount`.
- C-9: `withdrawLendPosition` debits CBT from Centuari custody 1:1 with the credited loan token. Sum-preserving on Centuari's books.
- C-10: `liquidationRepay` debits the **liquidator**, not the borrower.

## CentuariBondERC20

- BT-1: Only `MINTER` (= Centuari) can `mint`.
- BT-2: `burn(amount)` burns msg.sender's balance; `burnFrom(account, amount)` spends allowance + burns account.
- BT-3: Standard ERC20; no transfer hooks.

## Settlement

- S-1: `_settledMatches[matchId]` is set BEFORE the external call to Centuari (CEI).
- S-2: Operator cannot replay a match: second call with same matchId reverts `AlreadySettled`.
- S-3: `_validateMatchData` rejects zero address fields, zero amount, zero timestamp, zero maturity, lender==borrower.
- S-4: Settlement does not validate `marketId == keccak256(loanToken, maturity)`. Operator-trusted.
- S-5: `nonReentrant` guards prevent intra-Settlement reentry.

## CollateralManager

- CM-1: `_flagLock <= MAX_FLAG_LOCK (30 days)`.
- CM-2: `_unflag` requires `flaggedAt > 0`, `block.timestamp >= flaggedAt + _flagLock`, and `IRiskModule.canUnflag(user, asset)`.
- CM-3: Both `flagFor` (operator) and `flag` (direct) call the same `_flag` helper.
- CM-4: Both `unflagFor` and `unflag` call the same `_unflag` helper.
- CM-5: Flag does not perform HF check (flagging strictly improves HF).

## RiskModule

- RM-1: `canUnflag(user, asset)` returns true iff post-unflag `hf >= 1e18 + maxBufferBps * 1e18 / 1e4` OR the user has no debt.
- RM-2: `canWithdraw(user, asset, amount)` returns true if `asset` is not flagged (regardless of debt). Else post-withdraw HF >= 1+buffer.
- RM-3: `isLiquidatable(user)` returns true iff user has priced debt AND `hf < 1e18`.
- RM-4: `healthFactor(user)` returns `type(uint256).max` for users with no debt; `0` for fail-closed; else 1e18-scaled HF.
- RM-5: Any unpriced/stale collateral (with non-zero amount that contributes to flagged) OR debt asset causes `canWithdraw`/`canUnflag` to return false (fail-closed).
- RM-6: `_computeHf` reads debt before collateral; debt-free users skip the collateral oracle loop (gas + correctness against stale collateral).
- RM-7: HF formula: `hf = (collateralUsd - debtUsd) * ltvWeighted / collateralUsd / debtUsd`.

## LiquidationEngine

- LE-1: Liquidation triggers on `block.timestamp >= maturity` OR `RiskModule.isLiquidatable(borrower) == true`.
- LE-2: Close factor enforced: `repaid <= debt * closeFactor / BPS`.
- LE-3: `collateralSeized` is capped at `available(borrower, collateralAsset)`; when capped, `repaid` is recomputed from collateral USD.
- LE-4: Liquidator's BalanceLedger.available is debited; never the borrower's loan-token balance.
- LE-5: `BalanceLedger.unmarkCollateral` is called iff the borrower's collateral asset balance reaches exactly zero after seizure.
- LE-6: `slippageExceeded` reverts if `collateralSeized < minCollateralOut`.
- LE-7: `_usdToBaseUnits` is provider-agnostic — uses the oracle's own linearity (probe at 1e18) to invert amount→USD.
- LE-8: Bonus cannot exceed BPS (100%); close factors must be > 0 and <= BPS.

## OracleRouter

- OR-1: `tryGetUsdValue` never reverts; returns `(0, false)` on any failure path.
- OR-2: `_maxStaleness[asset] == 0` causes `tryGetUsdValue` to return `(0, false)` — fail-closed on unconfigured staleness.
- OR-3: `setMaxStaleness(asset, 0)` reverts (SC-3 invariant: priced assets must have explicit staleness windows).
- OR-4: Tokens with decimals > 36 return `(0, false)` to prevent `10**dec` overflow.

## PushOracle

- PO-1: `setPrice` reverts if `price < minPrice` OR `price > maxPrice`.
- PO-2: After the first push, `setPrice` reverts if `|price - prev| > prev * maxDeviationBps / BPS`.
- PO-3: First push (when `_updatedAt == 0`) is exempt from the deviation guard.
- PO-4: Only `_operator` can call `setPrice`.
- PO-5: Owner can rotate operator, set bounds, set max deviation bps.

## ChainlinkPriceFeed

- CL-1: Returns `(0, 0)` (fail-closed) when sequencer is down OR within sequencer grace period OR sequencer feed unhealthy.
- CL-2: Returns `(0, updatedAt)` on incomplete round (answer ≤ 0, updatedAt == 0, startedAt == 0, answeredInRound < roundId).
- CL-3: Scales Chainlink decimals to 1e18.

## Cross-component

- X-1: BalanceLedger writers list contains exactly: {Centuari, CollateralManager, LiquidationEngine, HubDepositor, WithdrawalRegistry, HubIntentSettler} as configured by owner. CollateralManager and LiquidationEngine writes require BalanceLedger to be a writer.
- X-2: Centuari's `_liquidationEngine` matches LiquidationEngine's deployed address; otherwise `liquidationRepay` reverts and liquidations are bricked.
- X-3: CollateralManager's `_riskModule` and LiquidationEngine's `_riskModule` are the same RiskModule (assumed; not enforced on-chain).
- X-4: RiskModule's `_oracle`, LiquidationEngine's `_oracle`, and OracleRouter's address are all the same. Otherwise the HF math used by RiskModule and the seizure math used by LiquidationEngine read from different price sources.

## Adversarial framings for Phase 4

The Phase 4 agents will attempt to falsify the following:

- F-1: Operator key can drain protocol funds via fake settlements (lender debited without consent).
- F-2: Reentrancy via any callback (ERC20 hooks, bond token, oracle feed, liquidation auto-unflag).
- F-3: HF can be artificially inflated to bypass liquidation trigger.
- F-4: PushOracle deviation guard can be defeated by multi-call in one tx / block.
- F-5: ChainlinkPriceFeed allows clamped (circuit-breaker) prices to be used.
- F-6: Day-count interest can produce surprising values (negative, overflow, zero on long loans).
- F-7: Bond token accounting can drift from `_marketTotalCbt`.
- F-8: A borrower can lock out their own liquidation by causing the oracle to fail-close on their assets.
- F-9: Liquidation can yield more collateral than the borrower owns (negative balance underflow).
- F-10: `_marketLoanToken` corruption via marketId collision / overwrite.
- F-11: `seedBorrowerMarkets` can fabricate non-existent debt for a borrower.
- F-12: `markCollateral` can be called by an unauthorized address.
- F-13: Storage layout is breakable via `__gap` math errors.
- F-14: ReentrancyGuard storage collision in proxy upgrade path.
- F-15: Withdraw after maturity yields more than `principal + interest`.
- F-16: Liquidation while paused (BalanceLedger / Centuari / LE) bypasses safety.
- F-17: HF buffer (`maxBufferBps`) can be circumvented (canWithdraw passes with HF < 1+buffer).
- F-18: Operator can re-flag asset within 24h via tricks (re-flag immediately after unflag with no lock).
- F-19: USD-to-base-unit conversion in liquidation overshoots, draining more collateral than priced.
- F-20: Liquidator can collect bonus on a position that was already healthy when their tx landed (because trigger check uses stale block.timestamp/HF).
