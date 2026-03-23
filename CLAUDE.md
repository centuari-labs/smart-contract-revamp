# CLAUDE.md — Centuari Smart Contract Revamp

## Project

Centuari is a cross-chain fixed-rate credit protocol on EVM. This repo (`smart-contract-revamp`) is the ground-up redesign of the on-chain settlement layer. It implements the Segment 4 contract specifications from the full architecture document.

**Current state**: Core contracts implemented and partially tested. Two settlement architectures coexist — the original `Settlement.sol` + `Centuari.sol` + `Treasury.sol` flow, and the new `CentuariEndpoint.sol` + `BalanceLedger.sol` architecture. 41 of 323 tests failing. No static analysis configured. Security invariant tests are stubs.

**Target chain**: Arbitrum (Arbitrum Sepolia for testnet).

## Model Routing Policy

Default model: claude-sonnet-4-6

Use Sonnet for: implementing well-specified contract features, writing tests, running static analysis, refactoring with clear scope, fixing known bugs, writing NatSpec documentation.

Escalate to claude-opus-4-6 only when:
- Designing security-critical architecture from scratch (liquidation engine, oracle integration, access control system)
- Auditing a contract for subtle economic attacks (flash loan vectors, oracle manipulation, incentive misalignment)
- Debugging a security vulnerability with an unknown root cause
- Reviewing any change that touches liquidation, interest accrual, collateral valuation, or health factor logic
- Any task where getting it wrong means user funds at risk and the correct answer is not obvious

Future-proof rule: When a new model generation ships, run /improve-workflow to update model strings. Routing logic never changes.

Never use claude-haiku-* for any Centuari smart contract work.

## Toolchain

```bash
# Compile
forge build

# Run all tests
forge test

# Run single test file
forge test --match-contract CentuariEndpointTest

# Run single test function
forge test --match-test test_submitBatch_valid_signature

# Run with verbose traces
forge test -vvvv

# Run fuzz tests (when written)
forge test --match-test testFuzz_

# Coverage (lcov)
forge coverage --report lcov

# Format
forge fmt

# Local chain
anvil

# Deploy all (10-step orchestration)
./bin/run-all.sh

# Export ABIs
./bin/export-abi.sh

# Static analysis (not yet configured — install separately)
# pip install slither-analyzer && slither .
```

## Contract Architecture

### Core Settlement (Original — `src/core/centuari/` + `src/core/settlement/`)

```
Settlement.sol (upgradeable, ERC1967)
  ├── onlyOperator validates engine submissions
  ├── prevents double-settlement via _settledMatches[matchId]
  └── calls Centuari.settleMatch() per match

Centuari.sol (upgradeable, ERC1967)
  ├── settleMatch() — creates lend/borrow positions, mints CBT, calls Treasury
  ├── repay() — onlyOperator, reduces _borrowDebt
  ├── withdrawLendPosition() — post-maturity CBT redemption
  └── _interestWithDayCount() — canonical interest formula

Treasury.sol (AccessControl, non-upgradeable)
  ├── holds all ERC20 balances via mapping(address => mapping(address => uint256))
  ├── settle() — moves funds from lender to borrower + fees
  ├── repay() / withdrawLendPosition() — accounting adjustments
  └── recordBondMint() / burnBondForUser() — CBT balance tracking
```

### Core Settlement (New — `src/core/`)

```
CentuariEndpoint.sol (upgradeable)
  ├── HSM ECDSA signature verification (Invariant #1)
  ├── Strictly increasing nonce (Invariant #2)
  ├── Batch processing: matches, rollovers, refinances, liquidations, returns, grace periods
  └── CBT mint validation ±1 wei tolerance

BalanceLedger.sol (upgradeable)
  ├── Four sub-states: available / locked / inYieldRouter / yieldRouterShares
  ├── Collateral positions: ACTIVE / FROZEN / LIQUIDATING
  ├── lockForOrder / unlockFromOrder (TOCTOU fix)
  ├── deposit() / withdraw() — user-facing ERC20 transfers
  └── onlyAuthorized writer pattern (Invariant #9)

RiskModule.sol (upgradeable)
  ├── Weighted HF: sum(collateral_i_USD * liqThreshold_i) / totalDebtUSD
  ├── validateBorrow() — debt ceiling, min borrow, collateral check
  ├── Chainlink price feed integration
  └── User debt tracking: _userDebtUSD, _totalDebtAgainstAsset

LiquidationEngine.sol (upgradeable)
  ├── Permissionless liquidation with grace period enforcement
  ├── 50% max debt coverage per liquidation
  ├── Oracle freshness check (Invariant #11)
  ├── Liquidator whitelist for RWA assets
  └── Tiered bonus: 5%/8%/12% via AssetBehaviorRegistry

CollateralRegistry.sol (upgradeable)
  ├── RWA attestation processing from LayerZero
  ├── Replay prevention: usedAttestationIds + monotonic timestamps (Invariant #10)
  └── Keeper-driven Chainlink/pCBT price refresh

AssetBehaviorRegistry.sol (upgradeable)
  ├── Root config per whitelisted asset
  ├── 48h timelock on updates (Invariant #7)
  ├── Per-asset pause (conservative, no timelock)
  └── Market schedule integration for after-hours LTV buffer

YieldRouter.sol (upgradeable)
  ├── Deploys idle capital via IYieldAdapter (Aave/Compound/Morpho)
  ├── 60% per-protocol cap (MAX_PER_PROTOCOL_BPS)
  ├── 10% InsuranceReserve minimum (Invariant #8)
  └── Adapter emergency pause (72h auto-expiry, multisig-only)
```

### Market Identification

`bytes32 marketId = keccak256(abi.encode(loanToken, maturity))`

### Bond Tokens

`CentuariBondERC20.sol` — One ERC20 per (asset, maturity). Immutable MINTER. `mint()` / `burn()` onlyMinter. `redeem()` nonReentrant, post-maturity only.

`CentuariBondERC20Factory.sol` — `getOrCreate(loanToken, maturity)` deploys or returns existing.

## Protocol Mechanics Reference

### Interest Formula
```
interest = (principal * rateBPS * elapsedSeconds) / (RATE_PRECISION * SECONDS_PER_YEAR)
```
- `RATE_PRECISION = 10000` (basis points)
- `SECONDS_PER_YEAR = 365 days = 31536000`
- Used in: `Centuari._interestWithDayCount()`, `CentuariEndpoint._computeExpectedCBT()`
- CBT amount = principal + interest
- On-chain validation: ±1 wei tolerance (`CBT_TOLERANCE = 1`)

### Health Factor Formula
```
HF = sum(collateral_i_USD * liqThreshold_i) / totalDebtUSD
```
- `HF_PRECISION = 1e18`
- Computed in `RiskModule._getWeightedCollateralUSD()`
- Uses cached `usdValueCached` from `BalanceLedger.CollateralPosition`
- Collateral refresh: `CollateralRegistry.refreshCollateralValues()` via keeper
- HF < 1e18 = liquidatable

### Liquidation Flow
1. `LiquidationEngine.liquidate()` — anyone can call (permissionless for non-RWA)
2. Checks: HF < 1.0, no active grace period, debtToCover <= 50% of total debt
3. Oracle freshness check (`isPriceFresh`)
4. Collateral enabled + active check
5. Liquidator whitelist check (RWA only)
6. Compute seizure with bonus: `debtWithBonus = debtToCover * (10000 + bonusBPS) / 10000`
7. `ledger.reduceCollateral()` + `riskModule.reduceUserDebt()`

### Settlement Flow (CentuariEndpoint)
1. Verify ECDSA signature from authorized HSM signer
2. Verify nonce == lastProcessedNonce + 1
3. Verify timestamp within ±60s
4. Process in order: liquidations -> returns -> rollovers -> refinances -> matches -> grace starts
5. Update nonce, emit SettlementBatchConfirmed

## Security Invariants

These MUST NEVER be violated. Any code change that could violate one requires explicit security review.

### Financial Invariants

1. **HSM signer authority** — Only `_authorizedSigner` can submit settlement batches. `ecrecover` on every batch. (CentuariEndpoint)
2. **Strictly increasing nonce** — `batch.nonce == _lastProcessedNonce + 1`. Prevents replay. (CentuariEndpoint)
3. **SpokeVaultRWA release only via LayerZero** — `onlyLayerZeroFromHub` modifier. (SpokeVaultRWA)
4. **SpokePayout requires recall complete** — WithdrawalRegistry authorizes after recall. (WithdrawalRegistry + SpokePayout)
5. **YieldRouter recall atomic with settlement** — If recall fails and InsuranceReserve cannot cover, batch reverts. (YieldRouter)
6. **fillFor requires actual transfer** — `balanceOf` check before/after. (HubIntentSettler)
7. **AssetBehavior changes require 48h timelock** — `_lastUpdateAt[asset] + TIMELOCK_DURATION`. (AssetBehaviorRegistry)
8. **InsuranceReserve >= 10% of deployed** — `_wouldMaintainReserve()` checked on every deploy. (YieldRouter)
9. **BalanceLedger writes restricted** — Only `_authorizedWriters` can call state-changing functions. (BalanceLedger)
10. **Attestation replay prevention** — `usedAttestationIds` + monotonic timestamp per (user, asset, chainId). (CollateralRegistry)
11. **No stale price for liquidation** — `isPriceFresh()` checked before every liquidation. (LiquidationEngine)
12. **onIntentFilled only by Endpoint** — `onlyEndpoint` modifier. (CentuariRouter)
13. **isUsedAsCollateral toggle safety** — Cannot disable if it would drop HF below 1.0. (BalanceLedger)
14. **Debt ceiling enforcement** — Total debt against collateral type <= debtCeiling. (RiskModule + CentuariEndpoint)
15. **Anchor rate bounds** — Rollover/refinance rates within committed ±50 bps. (CentuariEndpoint)
16. **CentuariRouter token accounting** — Token balance == sum(unfilled intents) + sum(undelivered CBT). (CentuariRouter)

### Reentrancy Invariants

17. All state changes MUST complete before any external call (CEI pattern).
18. Liquidation functions MUST use nonReentrant.
19. Oracle reads are external calls — state must be finalized before oracle price gates state changes.

### Access Control Invariants

20. Admin functions MUST be timelocked where they affect user funds.
21. Users MUST always be able to withdraw available balance even when paused.
22. Storage layout MUST be preserved across upgrades. Use `__gap` in all upgradeable contracts.

### Codebase-Specific Invariants

23. **Interest MUST be accrued before any HF check** — debt must reflect current state.
24. **CBT mint amount validated ±1 wei** — `_computeExpectedCBT()` vs submitted `cbtMintAmount`. (CentuariEndpoint)
25. **Rounding favors protocol** — Integer division truncates down. Maintained by `(principal * rate * time) / (RATE_PRECISION * SECONDS_PER_YEAR)`.

## Known Vulnerabilities in This Class of Protocol

- **Oracle manipulation** — Attacker inflates collateral price, borrows max, walks away. Defense: Chainlink with staleness check, dual-oracle at maturity.
- **Flash loan + governance** — Flash borrow governance tokens, vote malicious. Defense: 48h timelock.
- **Liquidation griefing** — Front-run liquidation by adding collateral. Defense: snapshot HF at tx start.
- **Reentrancy via ERC777/callbacks** — Transfer hooks re-enter mid-state. Defense: CEI + nonReentrant + SafeERC20.
- **Interest accrual manipulation** — Timing to avoid accrual. Defense: accrue before every HF check.
- **Rounding accumulation** — Dust errors favor users over many txs. Defense: round in protocol's favor.
- **Decimal precision mismatch** — USDC (6) vs DAI (18) in multi-collateral. Defense: normalize to 18 dec.
- **Stale oracle in volatile markets** — Chainlink delay. Defense: `maxStaleness` per asset.
- **YieldRouter withdrawal failure** — External protocol paused. Defense: `canRecall()`, InsuranceReserve fallback.
- **Cached collateral values** — `usdValueCached` may be stale. Defense: keeper refresh. RISK: no on-demand refresh before HF check.
- **Low-level calls for CBT minting** — CentuariEndpoint uses `.call()`. Defense: replace with typed interface calls.
- **Withdrawal without HF check** — `BalanceLedger.withdraw()` doesn't verify HF. Defense: add RiskModule check.

## Gotchas

- Interest accrual timing: always accrue before reading HF. Wrong order = incorrect liquidation eligibility.
- Oracle staleness: check `block.timestamp - updatedAt <= maxStaleness` before any price-dependent operation.
- Decimal normalization: RiskModule normalizes via `10 ** (18 - feedDecimals)`.
- `RATE_PRECISION = 10000` (basis points). 500 = 5%, 800 = 8%.
- `SECONDS_PER_YEAR = 365 days` (no leap year).
- `HF_PRECISION = 1e18`. HF < 1e18 = liquidatable.
- Market ID = `keccak256(abi.encode(loanToken, maturity))`.
- Treasury uses `balances[address(this)][token]` for protocol-owned funds.
- CBT naming uses `DateTime.sol` library: "CBT {SYMBOL} {D} {Mon} {Year}".
- `CentuariEndpoint._processMatches()` uses low-level `.call()` for bond factory — silently succeeds on unexpected data.
- `YieldRouter.rebalance()` is a no-op (emits event only).
- `SecurityInvariants.t.sol` — all tests are `assertTrue(true)` stubs.
- 41 tests currently failing.
- Storage gaps: all `*Storage.sol` contracts have `uint256[N] private __gap`. Reduce when adding vars.
- `CentuariBondERC20` decimals match underlying: `DECIMALS` is immutable, set at deploy from loan token.
- `RiskModule._latestRoundData()` does NOT check `answer > 0` — negative/zero price accepted.

## Self-Improvement Rules

1. After identifying a new attack vector -> add to Known Vulnerabilities with date
2. After a security review finds an invariant violation -> add to Security Invariants with date
3. After finding a new non-obvious bug -> add to Gotchas with date
4. After any change to liquidation, HF, or interest logic -> the security-auditor agent MUST run on the changed files
5. When a new Claude model generation is available -> run /improve-workflow
