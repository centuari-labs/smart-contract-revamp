# Centuari Smart Contract Architecture

> Last updated: 2026-03-27 | Branch: fix/final-audit-cleanup

This document explains every contract, its purpose, how they connect, and the end-to-end flows. Read this first when onboarding.

---

## Table of Contents

1. [What Centuari Does](#1-what-centuari-does)
2. [Architecture Overview](#2-architecture-overview)
3. [Two Settlement Architectures](#3-two-settlement-architectures)
4. [Contract-by-Contract Reference](#4-contract-by-contract-reference)
5. [End-to-End Flows](#5-end-to-end-flows)
6. [Storage Pattern](#6-storage-pattern)
7. [Access Control Model](#7-access-control-model)
8. [Key Constants and Formulas](#8-key-constants-and-formulas)
9. [Cross-Chain Architecture](#9-cross-chain-architecture)
10. [File Organization](#10-file-organization)

---

## 1. What Centuari Does

Centuari is a **cross-chain, fixed-rate lending protocol** built on a hybrid CLOB (Central Limit Order Book). The key insight: orders are matched **off-chain** for speed (sub-100ms), but all settlement happens **on-chain** on Arbitrum for trustlessness.

**User journey**: Deposit tokens on any supported chain -> place lend/borrow orders (gasless, off-chain) -> engine matches orders -> settlement batch submitted on-chain -> lender receives CBT (bond token), borrower receives stablecoins -> at maturity, CBT redeems for $1.00.

**Why this architecture**: Fully on-chain CLOBs can't achieve sub-100ms matching. Traditional CEXs can't provide trustless settlement. Centuari's hybrid model (like Vertex Protocol, dYdX v4) achieves both.

---

## 2. Architecture Overview

```
                    OFF-CHAIN                          ON-CHAIN (Arbitrum Hub)
              ┌─────────────────┐              ┌───────────────────────────────────┐
              │ Matching Engine  │──HSM sign──>│ CentuariEndpoint.sol              │
              │ (order book,    │              │  (settlement batches, CBT mint)   │
              │  price-time     │              │                                   │
              │  priority)      │              │ BalanceLedger.sol                 │
              └────────┬────────┘              │  (all user balances)              │
                       │                       │                                   │
              ┌────────┴────────┐              │ RiskModule.sol                    │
              │ Maturity Engine │              │  (health factor, LTV)             │
              │ (rollovers,     │              │                                   │
              │  refinances)    │              │ LiquidationEngine.sol             │
              └─────────────────┘              │  (liquidation + grace periods)    │
                                               │                                   │
SPOKE CHAINS                                   │ YieldRouter.sol                   │
┌──────────────────┐                           │  (idle capital -> Aave/Compound)  │
│ SpokeVaultStable │──ERC-7683 solver──>       │                                   │
│ SpokeVaultRWA    │──LayerZero attest──>      │ CollateralRegistry.sol            │
│ SpokePayout      │<──withdraw auth────       │  (RWA attestation processing)     │
└──────────────────┘                           └───────────────────────────────────┘
```

### Hub-and-Spoke Model

- **Hub (Arbitrum)**: All intelligence — matching, settlement, risk, yield, liquidation
- **Spokes (Base, BNB, Polygon, etc.)**: Thin custody layers — lock assets, emit intents, receive payouts
- **BalanceLedger is an ACCOUNTING system**, not a custody system. When it shows 10,000 USDC available, that USDC may be in SpokeVaultStable on Base, in Aave via YieldRouter, or on Arbitrum directly.

---

## 3. Two Settlement Architectures

The codebase contains TWO settlement paths. This is intentional — the new architecture replaces the old, but both are deployed.

### Original Architecture (Legacy)
```
Settlement.sol --> Centuari.sol --> Treasury.sol
```
- **Settlement.sol**: Receives batch from operator (simple address check, no ECDSA). Validates matches, prevents double-settlement via `_settledMatches[matchId]`.
- **Centuari.sol**: Creates lend/borrow positions, computes interest, mints CBT to Treasury.
- **Treasury.sol**: Holds all ERC20 tokens. Internal `balances[user][token]` mapping. Moves funds between lender/borrower on settlement.

**Why legacy exists**: This was the v1 implementation. It works but has limitations — no HSM signature verification, no multi-collateral HF, no YieldRouter integration, no timelocks on admin functions.

### New Architecture (Current)
```
CentuariEndpoint.sol --> BalanceLedger.sol + RiskModule.sol + all other contracts
```
- **CentuariEndpoint.sol**: HSM ECDSA verification, strictly increasing nonce, batch processing with CBT mint tolerance check.
- **BalanceLedger.sol**: Four-state balance model (available/locked/inYieldRouter/yieldRouterShares) + collateral positions.
- Full integration with RiskModule, LiquidationEngine, YieldRouter, CollateralRegistry.

**Why the new architecture**: HSM-grade security (Invariant #1), multi-collateral health factor (Aave V3 pattern), yield on idle capital, on-chain grace periods, cross-chain RWA collateral.

---

## 4. Contract-by-Contract Reference

### Core Settlement

#### `CentuariEndpoint.sol` — Trust Anchor
**Purpose**: The single entry point for ALL on-chain state changes from the off-chain engine.

**What it does**:
- Verifies HSM ECDSA signature on every settlement batch (Invariant #1)
- Enforces strictly increasing nonce (Invariant #2 — prevents replay)
- Processes 6 operation types in order: liquidations -> returns -> rollovers -> refinances -> matches -> grace periods
- Validates CBT mint amounts within +-1 wei of the canonical formula
- Enforces anchor rate bounds for rollovers (+-50 bps)
- Normalizes debt to 18 decimals before recording in RiskModule
- Includes `redeemCBT()` for post-maturity CBT redemption

**Why this design**: The engine operator has full control over matching (off-chain). CentuariEndpoint is the on-chain check that prevents the engine from cheating — it can't mint excess CBT, replay old batches, or submit without HSM authorization.

**Key dependencies**: BalanceLedger (balance updates), CentuariBondERC20Factory (CBT minting), RiskModule (debt recording), FeeController (fee computation), AssetBehaviorRegistry (min borrow amount, debt ceiling).

---

#### `BalanceLedger.sol` — Balance Source of Truth
**Purpose**: Single source of truth for ALL user balances and collateral positions in the protocol.

**What it does**:
- Tracks four balance states per user per asset: `available`, `locked` (in open orders), `inYieldRouter` (deployed to DeFi), `yieldRouterShares`
- Manages collateral positions: `ACTIVE`, `FROZEN`, `LIQUIDATING` states
- Per-user per-asset toggle: `isUsedAsCollateral` (Aave V3 pattern)
- User-facing `deposit()` (with fee-on-transfer support) and `withdraw()` (with HF check)
- `lockForOrder()` / `unlockFromOrder()` — TOCTOU fix for order placement
- `transferOut()` — used by CentuariEndpoint during CBT redemption

**Why this design**: Separating balance accounting from settlement logic allows multiple contracts (CentuariEndpoint, WithdrawalRegistry, YieldRouter, LiquidationEngine) to modify balances through a single controlled interface. Write access restricted to authorized contracts only (Invariant #9).

**Critical invariant**: `withdraw()` omits `whenNotPaused` — users MUST always be able to withdraw (Invariant #21).

---

#### `RiskModule.sol` — Risk Computation Engine
**Purpose**: Pure computation contract for health factor, LTV enforcement, and borrow validation.

**What it does**:
- Computes weighted health factor: `HF = sum(collateral_i_USD * liqThreshold_i) / totalDebtUSD`
- Uses LIVE Chainlink oracle prices (not stale cached values) for HF computation
- L2 sequencer uptime check before accepting oracle data (Arbitrum-specific)
- `validateBorrow()` — checks collateral enabled, debt ceiling, HF >= 1.0, min borrow amount
- Tracks per-user debt (`_userDebtUSD`) and per-collateral-type debt (`_totalDebtAgainstAsset`)
- Dual oracle verification (`verifyDualOracle()`) for maturity processing
- Price sanity bounds (min/max) per asset

**Why this design**: Keeping risk computation separate from settlement allows any contract to query HF without coupling to settlement logic. The live oracle approach (vs cached) was a fix for a HIGH finding — stale prices could allow undercollateralized borrowing.

---

#### `LiquidationEngine.sol` — Liquidation Executor
**Purpose**: Executes liquidations for undercollateralized positions, with grace period enforcement.

**What it does**:
- Permissionless `liquidate()` — anyone can liquidate unhealthy positions
- 50% max debt coverage per liquidation (Aave V3 pattern)
- Oracle freshness check before every liquidation (Invariant #11)
- Liquidator whitelist for RWA assets (KYC requirement)
- Tiered liquidation bonus: 5% (hub-native), 8% (T+1 RWA), 12% (T+3 RWA)
- Grace period enforcement — positions in grace cannot be liquidated until deadline passes
- Cross-chain liquidation via LayerZero V2 for RWA on spoke chains
- `retryLiquidation()` for failed cross-chain messages

**Why this design**: Grace periods prevent mass liquidation from failed refinances at maturity. The tiered bonus incentivizes liquidators to take on harder-to-sell RWA collateral. Cross-chain liquidation is necessary because RWAs stay locked on their origin chain.

**Liquidation flow**: Check HF < 1.0 -> check grace period -> check 50% cap -> verify oracle freshness -> verify collateral active -> check liquidator whitelist -> compute seizure with bonus -> debit liquidator's debt payment -> reduce borrower's collateral -> credit collateral to liquidator -> reduce borrower's debt.

---

### Asset Configuration

#### `AssetBehaviorRegistry.sol` — Asset Configuration Root
**Purpose**: Single configuration layer for every whitelisted asset in the protocol.

**What it does**:
- Stores `AssetBehavior` struct per asset: class (A/B/C/D), yield mechanism, LTV, liquidation threshold, market hours, spoke mode, compliance flags, debt ceiling, min borrow amount
- 48h timelock on all additions and modifications (Invariant #7)
- Per-asset pause (no timelock — conservative action) and unpause (requires timelock)
- Discrete LTV governance: new LTV applies to new positions immediately, existing positions require separate `applyLTVToExisting()` after 30-day observation
- Liquidator whitelist management per asset

**Why this design**: Zero core contract changes needed when adding a new asset type (tokenized bond, stock, commodity). Just a registry update via governance vote. This is the mechanism for infinite asset extensibility.

**Asset classes**:
- **Class A** (Yield-Bearing Stable): OUSG, USDY, BUIDL — hold as-is, already earns yield
- **Class B** (Yield-Bearing Volatile): Dividend stocks — hold, apply distribution policy
- **Class C** (Non-Yielding Stable): USDC, USDT, USDe — deploy to YieldRouter
- **Class D** (Non-Yielding Volatile): Non-dividend stocks, PAXG — hold as-is

---

#### `CollateralRegistry.sol` — RWA Attestation Processing
**Purpose**: Receives and validates RWA collateral attestations from spoke chains via LayerZero.

**What it does**:
- Processes attestation messages: validates sender, checks `usedAttestationIds` (Invariant #10), enforces monotonic timestamps per (user, asset, chainId)
- Creates collateral positions in BalanceLedger with initial `usdValueCached`
- Keeper-driven price refresh: reads Chainlink feeds, updates cached USD values
- pCBT vault price integration for perpetual CBT collateral

**Why this design**: RWA tokens (OUSG, BUIDL) can't be bridged — they stay on their origin chain under compliance lock. Only a custody proof (attestation) travels to the hub via LayerZero. This registry validates and tracks those proofs.

---

#### `MarketScheduleRegistry.sol` — Market Hours
**Purpose**: Stores market hours schedules for tokenized equities.

**What it does**:
- Per-exchange schedules: opening/closing times (UTC), trading days, holiday calendars
- `isOpen(scheduleId)` — called by RiskModule to apply after-hours LTV buffers
- Supports NYSE, LSE, TSE, IDX, SGX, HKEX

**Why this design**: Tokenized stocks have stale price feeds during off-hours. The after-hours LTV buffer (e.g., -10%) protects against overnight gap risk.

---

### Yield & Capital Efficiency

#### `YieldRouter.sol` — Idle Capital Deployment
**Purpose**: Deploys idle user capital to external yield protocols (Aave V3, Compound V3, Morpho).

**What it does**:
- Deploys immediately on deposit per `AllocationConfig` (15% cash buffer, 85% to DeFi)
- `recall()` — atomic within settlement batch. If recall fails and InsuranceReserve can't cover, batch reverts (Invariant #5)
- `recallForOrder()` — recall shortfall when user places order exceeding cash buffer
- Per-protocol cap: 60% max to any single protocol (`MAX_PER_PROTOCOL_BPS`)
- InsuranceReserve: minimum 10% of deployed capital (Invariant #8)
- Adapter emergency pause: multisig-only, 72h auto-expiry
- `rebalance()` — redistributes capital across adapters (NOTE: has known bugs, needs rewrite)

**Why this design**: Class C stablecoins (USDC, USDT) earn 0% sitting idle. The router earns 3-6% APY from Aave/Compound while maintaining a 15% cash buffer for instant order placement. Phase 2 replaces external protocols with Centuari's own Mutual Fund Vaults.

---

#### `AaveV3Adapter.sol`, `CompoundV3Adapter.sol`, `MorphoAdapter.sol` — Yield Adapters
**Purpose**: Wrap external DeFi protocols behind a standard `IYieldAdapter` interface.

**What they do**:
- `deploy(asset, amount)` — supply to external protocol, return shares
- `recall(asset, shares)` — withdraw from external protocol, return amount
- Internal balance tracking (not `balanceOf`) to prevent donation/inflation attacks
- `canRecall()` — check if protocol has sufficient liquidity for recall

**Why adapters**: Isolates external protocol risk. If Aave is exploited, only the adapter needs to be paused. The YieldRouter never touches external protocols directly.

---

### Bond Tokens (CBT)

#### `CentuariBondERC20.sol` — Lend Position Token
**Purpose**: ERC-20 token representing a lender's fixed-rate position. One contract per (asset, maturity) pair.

**What it does**:
- Standard ERC-20 (fully transferable, composable with all DeFi)
- `mint()` — onlyMinter (CentuariEndpoint via factory)
- `burn(uint256)` — public, anyone can burn own tokens
- `burn(address, uint256)` — onlyMinter, for rollovers
- `redeem()` / `redeemTo()` — DISABLED (revert with `UseEndpointRedeem`). Redemption goes through `CentuariEndpoint.redeemCBT()`
- Decimals match underlying token (USDC CBT has 6 decimals)
- Immutable: MINTER, LOAN_TOKEN, MATURITY, DECIMALS

**Why not redeem on CBT directly**: CBT is non-upgradeable (immutable). The underlying tokens live in BalanceLedger, not in the CBT contract. Redemption must go through CentuariEndpoint which can burn CBT AND transfer underlying atomically.

#### `CentuariBondERC20Factory.sol` — CBT Deployer
**Purpose**: Deploys CBT contracts deterministically using CREATE2.

**What it does**:
- `getOrCreate(loanToken, maturity)` — deploy or return existing CBT
- Salt = `keccak256(abi.encode(loanToken, maturity))` — deterministic addresses
- Generates human-readable names: "Centuari Bond USDC Jun 2026" / "CBT-USDC-2026-06-01"
- Safe decimal fallback (18 if token doesn't implement `decimals()`)

---

### Perpetual CBT (pCBT)

#### `PCBTVault.sol` — Perpetual Composable Bond Token
**Purpose**: Wraps CBT into a perpetual ERC-20 that auto-rolls at maturity.

**What it does**:
- Users deposit CBT, receive pCBT shares (virtual shares with 1e6 offset for inflation defense)
- Withdrawal queue: request -> wait for maturity settlement -> receive USDC
- `onSettlement()` — called by CentuariEndpoint at maturity. Rolls CBT, processes withdrawal queue FIFO
- Early exit via secondary market order
- Share price reflects CBT fair value via CentuariRateOracle

**Why pCBT**: Regular CBT expires monthly. DeFi protocols and DAOs want a perpetual token they can hold indefinitely. pCBT auto-rolls under the hood.

#### `PCBTVaultFactory.sol` — pCBT Deployer
One vault per stablecoin denomination. Deploys ERC1967 proxy + implementation.

---

### DeFi Integration (Credit Kit)

#### `CentuariRouter.sol` — On-Chain Integration Entry Point
**Purpose**: Bridge between on-chain DeFi protocols and the off-chain matching engine.

**What it does**:
- `submitLendIntent()` / `submitBorrowIntent()` — external protocols deposit tokens + order params
- Engine detects events, places orders in CLOB
- `onIntentFilled()` — called by CentuariEndpoint after match. Delivers CBT to callback target (Invariant #12)
- Callback wrapped in try/catch with 200k gas limit — failed callbacks don't block settlement
- `claimUndeliveredCBT()` — fallback for failed callbacks
- Intent lifecycle: PENDING -> PARTIAL -> FILLED / CANCELLED / EXPIRED / CALLBACK_FAILED
- ERC-4626 vault adapter for simple deposit/withdraw interface

**Why this design**: On-chain smart contracts can't call off-chain APIs. CentuariRouter is the on-chain interface that the engine monitors. External protocols (Yearn, Gauntlet, Morpho) interact with Centuari through this contract.

---

#### `CentuariRateOracle.sol` — On-Chain Rate Feed
**Purpose**: Provides current market rates to external protocols without API dependency.

**What it does**:
- Engine commits VWAP rate snapshots every 100 settlement batches (signed by HSM)
- Anchor rates committed at T-1 hour before maturity (immutable once committed)
- `getRate()` — current rate for asset/maturity pair
- `getCBTFairValue()` — linear fair value: $1.00 / (1 + rate * timeRemaining)
- `isRateFresh()` — freshness check for integrators
- Rate bounds: +-500 bps max change per snapshot (anti-manipulation)
- Monotonic nonce per (asset, maturity) for replay prevention

---

### Fee System

#### `FeeController.sol` — Fee Logic
**Purpose**: Single contract containing ALL fee computation and distribution logic.

**What it does**:
- `computeMatchFees()` — taker fee (0.2%), maker rebate (-0.2%), settlement fees
- `computeRolloverFees()` / `computeRefinanceFees()`
- `validateAndExecuteFees()` — called by CentuariEndpoint during batch processing
- Fee parameters governance-controlled with 48h timelock
- Low-interest waiver: fees waived below configurable threshold

**Why separate**: Fee logic changes frequently (promotions, tier adjustments). Isolating it means CentuariEndpoint never changes when fees evolve.

#### `ProtocolTreasury.sol` — Fee Revenue Receiver
**Purpose**: Accumulates protocol fee revenue. Multisig-controlled withdrawals.

---

### Cross-Chain Infrastructure

#### `HubIntentSettler.sol` — ERC-7683 Hub Side
**Purpose**: Credits BalanceLedger when a solver fills a cross-chain deposit intent.

**What it does**:
- `fillFor()` — solver transfers tokens, BalanceLedger credited for user
- Verifies actual token transfer via `balanceOf` before/after (Invariant #6)
- Registers fill in SettlementLedger for async solver reimbursement

**Why**: Users on spoke chains get instant BalanceLedger credit (<3 seconds) because the solver fronts capital. The real bridging happens in the background.

#### `SettlementLedger.sol` — Solver Reimbursement Tracking
**Purpose**: Tracks which solver fills need reimbursement after Sweeper bridges real tokens.

#### `WithdrawalRegistry.sol` — Withdrawal Orchestration
**Purpose**: Manages the withdrawal lifecycle with sequential enforcement.

**What it does**:
- `requestWithdrawal()` — instant path if available >= amount, queued path otherwise
- State machine: PENDING -> PROCESSING -> COMPLETED / ESCALATED
- 4-hour SLA: escalation if withdrawal queued too long
- SpokePayout cannot release without authorization (Invariant #4)

---

### Spoke Chain Contracts

#### `SpokeVaultStable.sol` — Stablecoin Vault (per spoke chain)
**Purpose**: Locks stablecoins deposited by users on spoke chains.

**What it does**:
- `deposit()` / `withdraw()` for stablecoins (USDC, USDT, USDe)
- Maintains HIGH_WATER_MARK / LOW_WATER_MARK buffer for withdrawals
- Sweeper bridges excess to hub; replenishes when buffer low

#### `SpokeVaultRWA.sol` — RWA Vault (per spoke chain)
**Purpose**: Locks compliance-restricted RWA tokens permanently while position active.

**What it does**:
- `deposit()` — locks RWA, sends LayerZero attestation to hub CollateralRegistry
- `lzReceive()` — receives liquidation command from hub LiquidationEngine (Invariant #3)
- Source chain + sender verification on every incoming message
- Frozen asset detection and reporting

#### `SpokePayout.sol` — Withdrawal Executor (per spoke chain)
**Purpose**: Releases withdrawal funds to users on target spoke chain.

**What it does**:
- `release()` — only after WithdrawalRegistry authorization
- Validates stored authorization details (user, asset, amount) — callers can't substitute
- Draws from SpokeVaultStable buffer

---

### Libraries & Utilities

#### `DateTime.sol` — Date Formatting
Converts Unix timestamps to human-readable date components. Used by CentuariBondERC20Factory for CBT naming ("Centuari Bond USDC Jun 2026").

#### `ReentrancyGuardUpgradeable.sol` — Custom Reentrancy Guard
OpenZeppelin's ReentrancyGuardUpgradeable adapted for the project's inheritance pattern.

---

## 5. End-to-End Flows

### Flow A: Stablecoin Deposit (Spoke -> Hub)
```
User signs GaslessCrossChainOrder (EIP-712)
  -> Solver validates, calls SpokeIntentSettler.open() on Base
  -> Solver calls HubIntentSettler.fillFor() on Arbitrum
  -> BalanceLedger.credit(user, USDC, amount)
  -> USER IS LIVE (<3 seconds)
  -> [Background] Sweeper bridges real USDC via CCTP/LayerZero
  -> SettlementLedger.match() reimburses solver
```

### Flow B: Lend Order Match
```
User signs lend order (EIP-712, off-chain)
  -> Engine validates balance via BalanceLedger
  -> BalanceLedger.lockForOrder(user, USDC, amount)
  -> Engine matches against borrow order (off-chain, sub-100ms)
  -> Engine signs SettlementBatch with HSM key
  -> CentuariEndpoint.submitSettlementBatch():
     1. Verify ECDSA signature
     2. Verify nonce == lastProcessedNonce + 1
     3. Debit lender's available balance
     4. Credit borrower's available balance
     5. Mint CBT to lender (validated +-1 wei)
     6. Record borrow debt in RiskModule
     7. Process fees via FeeController
```

### Flow C: Auto Rollover (Maturity)
```
Maturity fires (1st of month, 00:00 UTC)
  -> Maturity Engine processes all expiring positions
  -> Internal netting: rollovers matched against refinances at anchor rate
  -> Excess released in staggered tranches over 2 hours
  -> Settlement batch: burn old CBT, mint new CBT with compounded interest
  -> Borrower's debt extended with interest settled (ADD_TO_LOAN or DEDUCT_COLLATERAL)
```

### Flow D: Liquidation
```
Chainlink price drops -> Keeper detects HF < 1.0
  -> Anyone calls LiquidationEngine.liquidate()
  -> Check HF < 1.0 (live oracle)
  -> Check grace period not active
  -> Check 50% max coverage
  -> Verify oracle freshness
  -> Compute seizure with bonus
  -> Debit liquidator's debt payment
  -> Reduce borrower's collateral
  -> Credit collateral to liquidator
  -> Reduce borrower's debt
```

### Flow E: CBT Redemption
```
After maturity: user calls CentuariEndpoint.redeemCBT(cbtAddress, amount)
  -> Verify maturity passed
  -> Burn CBT from user
  -> Verify BalanceLedger has sufficient underlying
  -> Transfer underlying from BalanceLedger to user
```

---

## 6. Storage Pattern

Every upgradeable contract follows the same pattern:

```
ContractStorage.sol (abstract)     <- All state variables + __gap
  |
Contract.sol (implementation)      <- All logic, inherits storage
  |
TransparentUpgradeableProxy       <- ERC1967 proxy
```

**Rules**:
- NEVER reorder, remove, or change types of existing variables in Storage contracts
- When adding new variables, append BEFORE `__gap` and reduce gap size
- Target: total slots (variables + gap) = ~50 per contract
- Constants don't occupy storage slots (compiled into bytecode)

Example: `BalanceLedgerStorage.sol` has state variables + `uint256[35] private __gap`

---

## 7. Access Control Model

### Pattern: Propose / Apply / Cancel (48h Timelock)
All security-sensitive admin setters use a three-step process:
1. `proposeX()` — owner sets pending value, starts 48h timer
2. `applyX()` — owner executes after timer expires
3. `cancelX()` — owner can cancel before timer expires

### Write Access Hierarchy
```
Owner (deployer multisig)
  -> proposes authorized writers/callers (48h timelock)

CentuariEndpoint (HSM-authorized)
  -> writes to BalanceLedger (credit, debit, lock, unlock)
  -> writes to RiskModule (record/reduce debt)
  -> mints/burns CBT

LiquidationEngine (permissionless for liquidate())
  -> writes to BalanceLedger (reduce collateral, add collateral)
  -> writes to RiskModule (reduce debt)

YieldRouter (authorized caller)
  -> writes to BalanceLedger (moveToYieldRouter, moveFromYieldRouter)

WithdrawalRegistry (authorized caller)
  -> writes to BalanceLedger (debit for withdrawals)
```

### Emergency Actions (No Timelock)
- `pause()` — conservative, blocks new operations
- `pauseAsset()` — per-asset pause
- `pauseAdapter()` — multisig-only, 72h auto-expiry

### Always Available (Even When Paused)
- `withdraw()` — Invariant #21, users must always be able to withdraw available balance

---

## 8. Key Constants and Formulas

### Interest Formula
```
interest = (principal * rateBPS * elapsedSeconds) / (RATE_PRECISION * SECONDS_PER_YEAR)
```
- `RATE_PRECISION = 10000` (basis points: 500 = 5%, 800 = 8%)
- `SECONDS_PER_YEAR = 365 days = 31,536,000`
- CBT amount = principal + interest

### Health Factor
```
HF = sum(collateral_i_USD * liqThreshold_i) / totalDebtUSD
```
- `HF_PRECISION = 1e18`
- HF < 1e18 = liquidatable
- All values in 18-decimal USD

### Market Identification
```
bytes32 marketId = keccak256(abi.encode(loanToken, maturity))
```

### CBT Naming
- Name: "Centuari Bond USDC Jun 2026"
- Symbol: "CBT-USDC-2026-06-01"
- Decimals: matches underlying (USDC CBT = 6 decimals)

---

## 9. Cross-Chain Architecture

### Transport Mechanisms
| Mechanism | Used For | Direction | Latency |
|-----------|----------|-----------|---------|
| ERC-7683 (Solver) | User deposits | Spoke -> Hub | <3 seconds |
| Circle CCTP | USDC bridging (Sweeper) | Spoke <-> Hub | 5-20 min |
| LayerZero OFT V2 | USDT/USDe bridging | Spoke <-> Hub | 5-20 min |
| LayerZero Messaging | RWA attestations, liquidation commands | Bidirectional | 2-10 min |

### Sweeper Bot (Off-Chain)
- Bridges excess from spoke vaults to hub (solver reimbursement)
- Replenishes spoke buffers when depleted by withdrawals
- Not on user's critical path — runs in background

---

## 10. File Organization

```
src/
├── adapters/              # External DeFi protocol wrappers
│   ├── AaveV3Adapter.sol
│   ├── CompoundV3Adapter.sol
│   └── MorphoAdapter.sol
├── core/                  # Hub contracts (Arbitrum)
│   ├── centuari/          # Legacy settlement architecture (v1)
│   │   ├── Centuari.sol
│   │   ├── CentuariStorage.sol
│   │   ├── CentuariBondERC20.sol         # Bond token (shared by v1 and v2)
│   │   └── CentuariBondERC20Factory.sol  # Bond token factory (shared)
│   ├── pcbt/              # Perpetual CBT vault
│   │   ├── PCBTVault.sol
│   │   ├── PCBTVaultFactory.sol
│   │   └── PCBTVaultStorage.sol
│   ├── settlement/        # Legacy settlement (v1)
│   │   └── Settlement.sol
│   ├── CentuariEndpoint.sol              # NEW settlement trust anchor
│   ├── BalanceLedger.sol                 # All user balances
│   ├── RiskModule.sol                    # HF computation, borrow validation
│   ├── LiquidationEngine.sol            # Liquidation + grace periods
│   ├── YieldRouter.sol                   # Idle capital deployment
│   ├── AssetBehaviorRegistry.sol         # Asset configuration
│   ├── CollateralRegistry.sol            # RWA attestation processing
│   ├── CentuariRateOracle.sol           # On-chain rate feed
│   ├── CentuariRouter.sol               # DeFi integration (Credit Kit)
│   ├── FeeController.sol                # Fee computation + distribution
│   ├── HubIntentSettler.sol             # ERC-7683 solver fills
│   ├── WithdrawalRegistry.sol           # Withdrawal lifecycle
│   ├── SettlementLedger.sol             # Solver reimbursement tracking
│   ├── MarketScheduleRegistry.sol       # Market hours for equities
│   ├── ProtocolTreasury.sol             # Fee revenue receiver
│   ├── Treasury.sol                     # Legacy fund custody (v1)
│   └── *Storage.sol                     # Storage layout contracts (one per upgradeable)
├── interfaces/            # All interface definitions
├── libraries/             # DateTime.sol
├── mocks/                 # Test mocks (MockToken, MockChainlinkFeed, etc.)
├── spoke/                 # Spoke chain contracts
│   ├── SpokeVaultStable.sol
│   ├── SpokeVaultRWA.sol
│   └── SpokePayout.sol
└── utils/                 # ReentrancyGuardUpgradeable.sol

test/
├── core/                  # Unit tests per contract
├── integration/           # End-to-end flow tests (FlowA through FlowI)
├── spoke/                 # Spoke contract tests
├── adapters/              # Adapter tests
└── centuari/              # Legacy architecture tests
```

---

## Quick Reference: Security Invariants

| # | Invariant | Enforced By |
|---|-----------|-------------|
| 1 | Only HSM signer submits batches | CentuariEndpoint |
| 2 | Strictly increasing nonce | CentuariEndpoint |
| 3 | SpokeVaultRWA release only via LayerZero from hub | SpokeVaultRWA |
| 4 | SpokePayout requires recall complete | WithdrawalRegistry |
| 5 | YieldRouter recall atomic with settlement | YieldRouter |
| 6 | fillFor requires actual token transfer | HubIntentSettler |
| 7 | AssetBehavior changes require 48h timelock | AssetBehaviorRegistry |
| 8 | InsuranceReserve >= 10% of deployed | YieldRouter |
| 9 | BalanceLedger writes restricted | BalanceLedger |
| 10 | Attestation replay prevention | CollateralRegistry |
| 11 | No stale price for liquidation | LiquidationEngine |
| 12 | onIntentFilled only by Endpoint | CentuariRouter |
| 13 | isUsedAsCollateral toggle safety | BalanceLedger |
| 14 | Debt ceiling enforcement | CentuariEndpoint + RiskModule |
| 15 | Anchor rate bounds | CentuariEndpoint |
| 16 | CentuariRouter token accounting | CentuariRouter |
