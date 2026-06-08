# Centuari Contracts — Invariants & Access-Control Matrix

> **Audience:** external security auditors. **Scope:** hub-only launch (Arbitrum), frozen at
> `smart-contract-revamp@a6e3bd8` (tag `audit/2026-06-07`). See
> [`dev-docs/audit/SCOPE.md`](../../dev-docs/audit/SCOPE.md) for the in/out-of-scope boundary.
>
> This document states, per in-scope contract, **the invariants the contract must always uphold**
> (the guarantees to try to break) and **its access-control surface** (every state-changing external
> function → required modifier → expected role holder). Invariants are derived from the contract logic
> and from the Foundry tests that prove them — each cites its source. If an invariant here disagrees
> with the code at the frozen commit, treat that as a finding.
>
> **Out of scope** (banner-annotated `@custom:audit-scope` in source, not documented here):
> `HubIntentSettler`, `SettlementLedger`, and all `spoke/*` contracts — dormant under hub-only.

---

## Global invariants (cross-contract)

| # | Invariant |
|---|---|
| G-1 | **BalanceLedger is the sole balance authority.** Centuari, Settlement, HubDepositor, WithdrawalRegistry, and LiquidationEngine express every balance change through `credit()` / `debit()` / `markCollateral()` / `unmarkCollateral()`. The ledger itself never holds tokens. |
| G-2 | **Writer-gating.** Only addresses pre-registered as authorized writers may mutate balances/flags. BalanceLedger state is therefore a pure function of authorized-writer call order. |
| G-3 | **RiskModule is the single HF policy seam.** Every health-factor decision (withdraw, unflag, liquidate) routes through the same RiskModule instance; governance can swap it without caller changes. |
| G-4 | **Collateral flags persist until explicit unflag.** Settlement auto-flags; `repay()` never unflags; only `CollateralManager.unflag*()` (after 24h lock + RiskModule gate) or `LiquidationEngine` (on full collateral drain) can clear a flag. |
| G-5 | **Market identity is immutable.** `marketId = keccak256(abi.encode(loanToken, maturity))`; a market's maturity can never change. |
| G-6 | **Fail-closed oracle model.** Any missing / stale / zero / non-standard price makes HF and liquidation checks return `false` (safe), never revert into an exploitable state. |

## Governance & upgrade surface

- **Pattern:** OpenZeppelin v5 upgradeable, ERC1967 Transparent proxy; each proxy has a dedicated
  ProxyAdmin (addresses in [`SCOPE.md`](../../dev-docs/audit/SCOPE.md) §2).
- **Testnet:** all `owner()` / ProxyAdmin / pauser held by the deployer EOA (iteration convenience).
- **Mainnet (designed, Track D1):** `deploy-hardened.sh` moves every owner/ProxyAdmin/pauser onto a
  Gnosis Safe (≥2-of-N) behind TimelockControllers — **24h** ops delay, **48h** upgrade delay — and
  asserts the deployer EOA owns nothing afterward.
- **Role legend used below:** *Governance* = owner (deployer EOA on testnet → Safe+timelock on
  mainnet); *Operator* = backend/settlement operator key; *Guardian* = pauser key.

---

## BalanceLedger

3-state balance model (`available` / `inOrders` / `inYieldRouter`) + on-chain collateral flag, writer-gated.

**Invariants**
- **BL-1** `available(user, asset)` = Σ credits − Σ debits for that pair at all times. *(credit/debit logic; `test_Credit_Success`, `test_Debit_Success`)*
- **BL-2** `inOrders()` and `inYieldRouter()` are always 0 in Phase 1 (slots reserved). *(`test_ForwardCompat_InOrdersAlwaysZero`, `…InYieldRouterAlwaysZero`)*
- **BL-3** `total()` = `available + inOrders + inYieldRouter`. *(BalanceLedger.sol `total()`)*
- **BL-4** `debit()` reverts `InsufficientBalance` when `available < amount` — balances never go negative. *(debit guard)*
- **BL-5** Re-marking an already-flagged (user, asset) does **not** refresh `_flaggedAt` — the flag-lock is pinned to the first mark. *(`markCollateral` idempotence)*
- **BL-6** A user can never exceed `MAX_FLAGGED_ASSETS` flagged assets (bounds the HF oracle loop; re-flagging an existing asset doesn't count). *(flag-set cap)*

**Access control**

| Function | Modifier | Holder |
|---|---|---|
| `credit` / `debit` / `markCollateral` / `unmarkCollateral` | `onlyAuthorizedWriter` | Centuari, HubDepositor, WithdrawalRegistry, LiquidationEngine |
| `proposeAuthorizedWriter` / `executeAuthorizedWriter` / `cancelWriterProposal` / `removeAuthorizedWriter` | `onlyOwner` | Governance |
| `forceAddWriter` | `onlyOwner` | Governance (early-deploy only) |
| `pause` / `unpause` | `onlyPauser` | Guardian |
| `setPauser` | `onlyOwner` | Governance |

## Centuari

Main lending/borrowing; `(loanToken, maturity)` markets; reads/writes BalanceLedger.

**Invariants**
- **CT-1** `marketId = keccak256(abi.encode(loanToken, maturity))` keys all position state. *(`_getMarketId`)*
- **CT-2** A borrower has at most `MAX_DEBT_MARKETS` active debt markets (one oracle call per market). *(debt-market enumeration)*
- **CT-3** When `repay()` / `liquidationRepay()` clears debt to zero, the market is removed from `_borrowerMarkets[borrower]`; set length is the sole source of `activeDebtCount()`. *(SC-8; market removal on zero debt)*
- **CT-4** `repay()` debits the borrower but **never** touches collateral flags. *(`test_repay_neverUnflagsEvenOnFullDebtClear`)*
- **CT-5** `settleMatch()` auto-marks each asset in `collateralAssets[]` (idempotent; no `_flaggedAt` refresh). *(settle auto-flag)*
- **CT-6** Lenders receive CBT = principal + day-count interest; Centuari custodies the CBT. *(CBT mint)*
- **CT-7** Borrower is credited gross `matchedAmount` and debited `matchedAmount + fees` (net = −fees). *(settle accounting)*

**Access control**

| Function | Modifier | Holder |
|---|---|---|
| `settleMatch` | `onlySettlement` | Settlement |
| `repay` | `onlyOperator` | Operator |
| `liquidationRepay` | `onlyLiquidationEngine` | LiquidationEngine |
| `withdrawLendPosition` | public | Lender (`msg.sender`) |
| `seedBorrowerMarkets` | `onlyOperator` | Operator (debt reconciliation) |
| `setSettlement` / `setBalanceLedger` / `setFeeCollector` / `setBondTokenFactory` / `setOperator` / `setLiquidationEngine` / `setPauser` | `onlyOwner` | Governance |
| `pause` / `unpause` | `onlyPauser` | Guardian |

### CentuariBondERC20Factory / CentuariBondERC20
- **CBF-1** Bond token addresses are CREATE2-deterministic with `marketId` as salt. **CBF-2** One bond token per market (`getOrCreate` returns existing or deploys). **CBF-3** Metadata reads are try-catch with safe fallbacks ("TOKEN", 18 decimals). **CBT-1** `mint` is `onlyMinter` (Centuari); `burn`/`burnFrom` are public to holders; decimals mirror the loan token.
- Access: `getOrCreate` `onlyCentuari`; `mint` `onlyMinter` (Centuari); views public.

## Settlement

Batch settlement processor; validates matches; prevents double-settle.

**Invariants**
- **ST-1** Each `matchId` settles at most once; a repeat reverts `AlreadySettled`. *(settled-set guard)*
- **ST-2** Every match field is validated non-zero and `lender != borrower` before settling. *(match validation)*
- **ST-3** The match is marked settled **before** the external `Centuari.settleMatch()` call (checks-effects-interactions; reentrancy-safe). *(ordering)*

**Access control**

| Function | Modifier | Holder |
|---|---|---|
| `settleMatches` / `settleMatch` | `onlyOperator` | Operator |
| `setOperator` / `setCentuari` / `setPauser` | `onlyOwner` | Governance |
| `pause` / `unpause` | `onlyPauser` | Guardian |

## HubDepositor

Hub-native deposit + token custody. (The gate-bypassing `payout()` was permanently removed in Track C6.)

**Invariants**
- **HD-1** `deposit()` pulls tokens via `safeTransferFrom` then credits BalanceLedger atomically; custody stays in HubDepositor. *(deposit path)*
- **HD-2** No `payout()` exists — all hub withdrawals flow through `WithdrawalRegistry`. *(C6 removal)*
- **HD-3** `payoutDirect()` releases tokens **without** debiting (the debit already happened in `WithdrawalRegistry._request()`); it is `onlyAuthorized`. *(payoutDirect)*

**Access control**

| Function | Modifier | Holder |
|---|---|---|
| `deposit` | public | Any user |
| `payoutDirect` | `onlyAuthorized` | WithdrawalRegistry (authorized caller) |
| `setAuthorizedCaller` / `addSupportedAsset` / `removeSupportedAsset` | `onlyOwner` | Governance |

## WithdrawalRegistry

Withdrawal state machine; HF gate is the first action.

**Invariants**
- **WR-1** `_request()` calls `IRiskModule.canWithdraw()` as its **first** action (closes the collateral-flag loophole, SC-6). *(request entry)*
- **WR-2** The user's balance is debited **before** any state mutation or dispatch — no double-withdrawal. *(debit-first)*
- **WR-3** Hub-native (`targetChainId == block.chainid`) completes in the same tx via `payoutDirect()`, transitioning straight to COMPLETED. *(hub shortcut)*
- **WR-4** State machine: PENDING → (PROCESSING | COMPLETED) → COMPLETED; FAILED is terminal from PENDING/PROCESSING. *(status transitions)*

> Note: the `setSpokeEid` / `setSpokeNativeRoute` / chain-liquidity machinery exists for the deferred
> cross-chain path; on the hub-only path only the hub-native shortcut (WR-3) is exercised.

**Access control**

| Function | Modifier | Holder |
|---|---|---|
| `requestWithdrawal` | public | User (`msg.sender`) |
| `requestWithdrawalFor` / `authorize` / `markCompleted` / `markFailed` | `onlyOperator` | Operator |
| `incrementChainLiquidity` | restricted | HubIntentSettler (cross-chain, dormant) |
| `setRiskModule` / `setHubDepositor` / `setOperator` / `setPauser` (+ spoke/route setters) | `onlyOwner` | Governance |
| `pause` / `unpause` | `onlyPauser` | Guardian |

## CollateralManager

Mid-life unflag path: 24h flag-lock + RiskModule gate.

**Invariants**
- **CM-1** Operator (`flagFor`/`unflagFor`) and direct (`flag`/`unflag`) entry points both funnel through `_flag()`/`_unflag()` — single uniform policy. *(seam)*
- **CM-2** Unflag is blocked until `block.timestamp >= flaggedAt + _flagLock` (default 24h), pinned to the first mark. *(flag-lock)*
- **CM-3** `unflag()` calls `IRiskModule.canUnflag()` after the lock check; fail-closed → reverts `WouldMakeUnhealthy`. *(HF gate)*
- **CM-4** `_flagLock` is capped at `MAX_FLAG_LOCK` (30 days) so governance can't disable unflagging. *(cap)*

**Access control**

| Function | Modifier | Holder |
|---|---|---|
| `flagFor` / `unflagFor` | `onlyOperator` | Operator |
| `flag` / `unflag` | public | User (self) |
| `setOperator` / `setRiskModule` / `setFlagLock` | `onlyOwner` | Governance |

## RiskModule

Oracle-backed HF policy; fail-closed.

**Invariants**
- **RM-1** If any required debt/collateral price is missing or stale, the check returns `false` (fail-closed, no revert). *(HF compute)*
- **RM-2** The HF loop reads **debt first**; a zero-debt user is immediately healthy and never fails-closed on stale collateral prices. *(SC-6 ordering)*
- **RM-3** Debt is deduped per loan token (one oracle call per distinct loan token, SC-5). *(`getBorrowerDebts`)*
- **RM-4** `HF = (collateralUsd − debtUsd)·weightedLTV / debtUsd`, `weightedLTV = Σ(cVal·ltv)/Σ(cVal)`, all 1e18-scaled. *(docstring)*
- **RM-5** Liquidation floor is HF < 1.0 (no buffer); withdraw/unflag gates use 1.0 + buffer. *(thresholds)*

**Access control:** all checks (`canWithdraw`/`canUnflag`/`isLiquidatable`/`healthFactor`) are views; `setOracle`/`setLtv`/`setBuffer`/`setDefaultBuffer` are `onlyOwner` (Governance).

## OracleRouter

**Invariants**
- **OR-1** `tryGetUsdValue()` returns `(0, false)` on missing feed / zero-or-stale price / unconfigured staleness window / decimals > 36 / feed revert — never reverts. *(read guards)*
- **OR-2** A zero `maxStaleness` means *unconfigured* → fail-closed (not "staleness disabled", SC-3). *(staleness)*
- **OR-3** Valuation is decimals-safe (try-catch `decimals()`, default 18). *(valuation)*

**Access control:** `tryGetUsdValue` view; `setFeed`/`setMaxStaleness` `onlyOwner` (Governance).

## LiquidationEngine

Permissionless liquidation.

**Invariants**
- **LE-1** A position is liquidatable iff HF < 1.0 (no buffer) **OR** (`block.timestamp >= maturity` AND debt > 0). *(trigger)*
- **LE-2** HF liquidations cap repay at `hfCloseFactorBps` (partial); matured liquidations use `maturedCloseFactorBps` (may be full). *(close factor)*
- **LE-3** Reverts if the collateral asset is not flagged in BalanceLedger. *(flag requirement)*
- **LE-4** If available collateral can't cover target repay + bonus, repay is backed down and bad debt may remain (no over-seize). *(collateral cap)*
- **LE-5** A fully-seized collateral asset (available → 0) is auto-`unmarkCollateral()`'d. *(auto-unmark)*
- **LE-6** Liquidator debits their own loan-token balance and receives seized collateral + bonus into `available`. *(settlement)*

**Access control**

| Function | Modifier | Holder |
|---|---|---|
| `liquidate` | public | Any liquidator (permissionless) |
| `setRiskModule` / `setOracle` / `setDefaultLiquidationBonus` / `setLiquidationBonus` / `setHfCloseFactor` / `setMaturedCloseFactor` / `setPauser` | `onlyOwner` | Governance |
| `pause` / `unpause` | `onlyPauser` | Guardian |

## Faucet (testnet only — excluded from mainnet)

- **FA-1** Per-token `maxPerRequest` (0 = unlimited) and `cooldown` (0 = none) enforced per (token, recipient). **FA-2** `mintBatch` capped at `MAX_BATCH = 9`.
- Access: `mintTo`/`mintBatch` `onlyOperator`; `addToken` owner-or-operator; `removeToken`/`setTokenConfig`/`setOperator` `onlyOwner`.

---

## How this maps to tests

Invariants above are encoded in `test/*.t.sol` (≈650 unit/integration assertions at the frozen commit)
plus storage-layout snapshots in `test/snapshots/` (CI-enforced upgrade safety). Phase 2.2 of audit prep
adds Foundry **invariant/fuzz harnesses** for the state machines most worth property-testing
(BalanceLedger accounting, WithdrawalRegistry transitions, RiskModule HF math, CollateralManager
flag-lock timing) — these turn the prose invariants above into executable properties.
