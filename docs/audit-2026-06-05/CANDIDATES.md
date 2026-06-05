# Candidate Findings Ledger

audit_date: 2026-06-05
source_commit: 8a9451194e27df4abaced439d1c49e119a9b2456

This ledger captures every candidate surfaced during Phase 4 + my own pass,
along with the rejection-with-proof or PoC status. Findings that survived the
validity gate are promoted to `findings/{SEVERITY}_{slug}.md` in Phase 8.

Severity tiers used: CRITICAL / HIGH / MEDIUM / LOW / INFO.
Confidence is 0-100. Recommended for PoC = whether Phase 7 should attempt a
falsifying test.

---

## CRITICAL

### C1: `Centuari.withdrawLendPosition` allows cross-market drain via mismatched (marketId, loanToken, maturity)

- **Severity (post-gate):** CRITICAL
- **Confidence:** 99
- **Affected:** `src/core/centuari/Centuari.sol:329-357`
- **PoC status:** PASSING (`test/exploits/centuari-2026-06-05/WithdrawCrossMarketDrain.t.sol`)
- **Discovered by:** orchestrator (manual review)

**Root cause.** `withdrawLendPosition(bytes32 marketId, address loanToken, uint256 maturity, uint256 cbtAmount)` resolves the bond token from the `(loanToken, maturity)` pair (line 337) but accounts position checks and decrements against the operator-supplied `marketId` (lines 342, 345, 350-351). Nothing asserts `marketId == keccak256(abi.encode(loanToken, maturity))` or that `_marketLoanToken[marketId] == loanToken`. The credit at line 354 writes the *caller-supplied* `loanToken`. Any lender holding a position at any marketId can drain Centuari's bond-token custody for any DIFFERENT matured `(loanToken_target, maturity_target)` market — receiving `cbtAmount` of `loanToken_target` instead of the token they actually lent.

**Attack path (CrossMarket drain, see PoC test `testExploit_CrossMarketWithdrawDrains`).**
1. Attacker lends 100 USDC into market A → `_lendPositionCbtAmount[mid_A][attacker] = 100`. Centuari now holds 100 `bondToken_USDC_T1`.
2. Victim lends 100 DAI into market B → `_lendPositionCbtAmount[mid_B][victim] = 100`. Centuari now holds 100 `bondToken_DAI_T2`.
3. Both maturities elapse.
4. Attacker calls `withdrawLendPosition(mid_A, DAI, maturityB, 100e18)`.
5. The function loads `bondToken = factory.getBondToken(DAI, maturityB)` → canonical `bondToken_DAI_T2`. Maturity check passes against `maturityB`. Position checks at `mid_A` pass (attacker has 100 CBT there). Centuari's `bondToken_DAI_T2.balanceOf` (=100) covers the burn.
6. The burn drains Centuari's `bondToken_DAI_T2` to 0. `_lendPositionCbtAmount[mid_A][attacker]` -> 0. Attacker is credited 100 DAI.
7. When the victim attempts their canonical withdraw (`mid_B, DAI, maturityB`), the burn reverts on `ERC20InsufficientBalance`. Victim is permanently locked out.

**Attack path (early-withdraw variant, see `testExploit_EarlyWithdrawViaShorterMaturityMarket`).**
The maturity check uses the loan token's maturity, not the position's market maturity. An attacker with a 1-year USDC position can drain the same loan token from a 1-day USDC market the moment the latter matures — pulling their long-dated position 364 days early and destroying the short-market lender's claim.

**Quantified impact.** Per-attacker drain ≤ `min(_lendPositionCbtAmount[X][attacker], Centuari.bondToken_Y.balanceOf)`. Collectively, lenders at any market(s) X can drain `Σ _marketTotalCbt[X]` worth of any other market's reserves, picking the token that maximises their take. Combined with the early-withdraw variant, every lender can extract their position at the FIRST maturity of any market sharing their bond-token, regardless of their own market's tenor.

**Smallest falsifier.** The PoC at `test/exploits/centuari-2026-06-05/WithdrawCrossMarketDrain.t.sol` runs in 8ms locally:
```
forge test --match-path "test/exploits/centuari-2026-06-05/WithdrawCrossMarketDrain.t.sol" -vv
```
Both `testExploit_CrossMarketWithdrawDrains` and `testExploit_EarlyWithdrawViaShorterMaturityMarket` PASS — i.e., the attack succeeds end-to-end.

**Strongest triager rejection.** "But the lender's position at marketId X has a corresponding bond-token supply at canonical (X's loanToken, X's maturity). They lose that supply too."  
**Counter.** The cross-market PoC explicitly verifies that `bondToken_USDC_T1` (the attacker's actual market) is **untouched** — `assertEq(bondA.balanceOf(centuari), 100 ether, "bondA POST = 100 (intact)")`. The burn went to `bondToken_DAI_T2`. The attacker keeps their original market's bond supply intact AND drains a different one.

**Recommended fix.**
```solidity
// In Centuari.withdrawLendPosition, before any state mutation:
if (marketId != keccak256(abi.encode(loanToken, maturity))) revert InvalidAmount();
```
Equivalent stricter form: derive marketId locally and ignore the parameter:
```solidity
bytes32 mid = _getMarketId(loanToken, maturity);
// then use `mid` everywhere, removing the marketId parameter from the signature.
```
The second form makes the parameter ambiguity impossible by construction.

**Gate failures.** none (all four validity gates pass; PoC PASSES).

---

## HIGH

### H1: `ChainlinkPriceFeed` missing min/maxAnswer (circuit-breaker) bounds check

- **Severity (post-gate):** HIGH
- **Confidence:** 95
- **Affected:** `src/core/oracle/ChainlinkPriceFeed.sol:58-66`, `src/interfaces/external/AggregatorV3Interface.sol`
- **PoC status:** NOT_BUILT (dormant on Sepolia; mainnet wiring pending)
- **Discovered by:** oracle vuln-hunter agent

**Root cause.** The wrapped `AggregatorV3Interface` exposes only `decimals()` and `latestRoundData()`. The contract checks `answer > 0`, `updatedAt > 0`, `startedAt > 0`, `answeredInRound >= roundId`, but never reads the underlying `Aggregator.minAnswer()` / `maxAnswer()` circuit-breaker bounds. Confirmed by `grep -rn "minAnswer\|maxAnswer" src/` returning no matches.

**Attack path.** Black-swan price move beyond Chainlink's configured min/max → Chainlink returns the clamped value (e.g. UST/Venus, May 2022, clamp at $0.10 while UST traded at $0.005). Borrowers with clamped-token collateral are over-valued; debt against clamped tokens is under-valued. Liquidations fail or under-extract, leaving bad debt; or honest borrowers are wrongly liquidated against an artificially-high collateral price.

**Quantified impact.** Direct historical precedent (Venus / LUNA): ~$11M drained when LUNA crashed past its min bound. Magnitude scales with the protocol's TVL on clamped tokens.

**Smallest falsifier.** Mock an aggregator that returns `minAnswer` regardless of underlying price; observe Centuari accept it as valid and route it through HF math.

**Strongest triager rejection.** "Dormant on Arb Sepolia. The PushOracle is the active oracle today."  
**Counter.** The contract is IN scope per the audit instructions; explicit NatSpec at `ChainlinkPriceFeed.sol:18` says "Dormant on Arb Sepolia (all assets currently use PushOracle); wired only once a real Chainlink feed is available." The audit gates the mainnet rollout. Shipping the unbounded-clamp adapter as-is is the canonical mainnet footgun.

**Recommended fix.** Add an `AccessControlledOffchainAggregator`-style interface, cache `minAnswer + EPS` and `maxAnswer - EPS` at construction, and return `(0, 0)` when `answer == minAnswer || answer == maxAnswer` (fail-closed at the rail).

**Gate failures.** none.

---

### H2: `PushOracle` deviation guard defeated by same-block multi-call

- **Severity (post-gate):** HIGH
- **Confidence:** 95
- **Affected:** `src/core/oracle/PushOracle.sol:80-94`
- **PoC status:** NOT_BUILT (single-line confirmation via re-read of state)
- **Discovered by:** oracle vuln-hunter agent

**Root cause.** `setPrice` updates `_price1e18` on every call and the deviation guard compares only to the previous stored value. No per-block / per-tx rate limit. A compromised operator key can chain N calls: 100 → 50 → 25 → 12.5 → ... each within the 50% deviation bound but compounding to >99% drop in one transaction.

**Attack path.** Operator key compromise (the protocol explicitly documents operator as a trusted role, but the guard's whole purpose is to limit damage from such compromise). Single attacker tx with N `setPrice` calls walks the price arbitrarily. Downstream: collateral oracle drops → RiskModule says position is liquidatable → liquidator (the attacker) seizes huge collateral for tiny repay (`LiquidationEngine.sol:146-150`, `_usdToBaseUnits` at lines 197-202 yields a huge `collateralSeized`). 

**Quantified impact.** Unbounded relative to the asset's TVL. The PushOracle controls all RWA price feeds (IDRX, XSGD, XAUT, SLVon, NVDAon, AAPLon, TLTon per the doc).

**Smallest falsifier.** Single-tx loop. PoC trivial.

**Strongest triager rejection.** "Operator is trusted."  
**Counter.** The `_maxDeviationBps` defense exists explicitly because operator compromise is in the threat model (see `PushOracle.sol:21-24`: "SC-2 hardening: every push is sanity-checked..."). The guard fails its stated objective.

**Recommended fix.** Require `block.timestamp > _updatedAt + MIN_PUSH_INTERVAL` between pushes (effectively rate-limiting per block) OR track a rolling 24h max deviation across pushes.

**Gate failures.** none.

---

## MEDIUM

### M1: `PushOracle` deploys with `[_minPrice=1, _maxPrice=type(uint256).max]` and deploy scripts never call `setBounds` / `setMaxDeviationBps`

- **Severity (post-gate):** MEDIUM
- **Confidence:** 90
- **Affected:** `src/core/oracle/PushOracle.sol:62-75`; `script/DeployRiskModule.s.sol`; `script/RedeployPushOracles.s.sol`
- **PoC status:** NOT_BUILT (verified by grep)
- **Discovered by:** oracle vuln-hunter agent

`grep -rn "setBounds\|setMaxDeviationBps" script/` returned zero matches. The deploy scripts deliberately defer bounds tightening to "the owner later if desired" (`RedeployPushOracles.s.sol:16-18`). Until owner manually tightens, the absolute bounds are effectively `[1 wei of 1e18-USD, +∞]`. The deviation guard's first-push exemption (line 84) then lets the operator anchor at any value.

**Recommended fix.** Constructor or initial deploy script MUST call `setBounds` per asset with sane bounds before the feed is exposed in `OracleRouter.setFeed`. Equivalently, `OracleRouter.tryGetUsdValue` should reject feeds whose `_maxPrice == type(uint256).max` or `_minPrice == 1`.

### M2: `PushOracle.setBounds` does not re-validate the stored `_price1e18` against new bounds

- **Severity (post-gate):** MEDIUM
- **Confidence:** 90
- **Affected:** `src/core/oracle/PushOracle.sol:105-110`, `:121-123`
- **PoC status:** NOT_BUILT
- **Discovered by:** oracle vuln-hunter agent

`setBounds(min, max)` only validates the new bounds against each other (line 106). The currently-stored `_price1e18` may now be outside the new bounds, but `latestPriceUsd()` keeps returning it. The next `setPrice` reverts on `PriceOutOfBounds`. The oracle is effectively frozen with an out-of-bound price until governance tunes again.

**Recommended fix.** `setBounds` should zero `_updatedAt` (forcing fail-closed via staleness) OR explicitly re-validate `_price1e18 ∈ [min, max]` and revert if not.

### M3: `Centuari.repay` and `Centuari.liquidationRepay` do not validate `loanToken == _marketLoanToken[marketId]`

- **Severity (post-gate):** MEDIUM
- **Confidence:** 90
- **Affected:** `src/core/centuari/Centuari.sol:243-274` (`repay`), `:284-311` (`liquidationRepay`)
- **PoC status:** NOT_BUILT
- **Discovered by:** orchestrator (manual review)

The `loanToken` parameter is operator/engine-controlled and used to address the BalanceLedger debit (lines 268, 308), while the debt is keyed by the *separate* `marketId` parameter. The two are not linked. An operator can pass `loanToken = DAI` to `repay(marketId_USDC, ...)` and the borrower's DAI balance is debited while the USDC debt is zeroed. `LiquidationEngine.liquidate` derives marketId from `(loanToken, maturity)` so the engine path is internally consistent, but a future contract added as `_liquidationEngine` need not be.

For external attackers this is gated by operator/engine trust, hence MEDIUM not HIGH. But it is a defensive check that should exist: a single typo on the operator side silently mints accounting drift between debt and balance.

**Recommended fix.**
```solidity
if (loanToken != _marketLoanToken[marketId]) revert InvalidAmount();
```
applied to both `repay` (after the `debt == 0` check) and `liquidationRepay`.

### M4: Settlement batch DoS via fresh-address `_flaggedAssets` saturation

- **Severity (post-gate):** MEDIUM
- **Confidence:** 75
- **Affected:** `src/core/collateral/CollateralManager.sol:114-116` (permissionless `flag(asset)`); `src/core/balance-ledger/BalanceLedger.sol:140-152` (MAX_FLAGGED_ASSETS cap); `src/core/centuari/Centuari.sol:185-187` (settleMatch markCollateral loop); `src/core/settlement/Settlement.sol:76-100` (batch atomicity)
- **PoC status:** NOT_BUILT (concept verified via code path)
- **Discovered by:** collateral/settlement vuln-hunter agent

`CollateralManager.flag(asset)` is permissionless and does not check the caller actually holds the asset. An attacker fills a fresh address with 32 garbage flags (one per `flag()` call), then submits a borrow order with one additional `collateralAssets[]` entry. When the operator batches that order, `markCollateral` reverts on the 33rd entry → entire `settleMatches` batch reverts.

This is an operator-griefing vector. The operator can pre-filter off-chain but the race window between read and on-chain settlement is exploitable.

**Recommended fix.** Either:
- Require `flag(asset)` to check `BalanceLedger.available(msg.sender, asset) > 0`, OR
- Catch the per-match `markCollateral` revert inside `Settlement._processMatch` and continue with other matches (drops only the malicious match, not the batch).

### M5: LiquidationEngine multi-call within one tx defeats the per-call close factor for severely-underwater positions

- **Severity (post-gate):** MEDIUM
- **Confidence:** 78
- **Affected:** `src/core/liquidation/LiquidationEngine.sol:107-189` (close-factor cap lines 132-135); doc in `LiquidationEngineStorage.sol:25-27`
- **PoC status:** NOT_BUILT (math derivation supports the claim)
- **Discovered by:** liquidation vuln-hunter agent

`liquidate` enforces close factor per call but is callable multiple times in the same transaction. For HF<<1 positions, post-liquidation HF stays below 1 (especially because the bonus extraction widens the underwater gap), so the second call's `isLiquidatable` check passes. N calls extract `1 - (1 - cf)^N` of the original debt.

The storage docstring at `LiquidationEngineStorage.sol:25-27` says close factor exists "to avoid over-liquidating a *merely-unhealthy* position". For severely-underwater positions, multi-call hits 75% (2 calls) / 87.5% (3 calls) with cf=50%.

This matches industry-standard Aave behavior, so a triager may reject as design-by-intent. The protocol's stated intent is stricter.

**Recommended fix.** Either:
- Per-block (or per-position) cooldown on `liquidate`, OR
- Relax the docstring to acknowledge multi-call as accepted behavior for underwater positions.

---

## LOW

### L1: `PushOracle.setOperator` does not reset price anchor — rotated operator inherits poisoned `_price1e18`

- **Severity:** LOW
- **Confidence:** 95
- **Affected:** `src/core/oracle/PushOracle.sol:97-102`
- **PoC status:** NOT_BUILT

If the prior operator pushed a poisoned price as their last act, the deviation guard bounds the new operator to ±50% of the poisoned value, requiring ~40 push tx to recover from `1e30` back to `1e18`.

**Recommended fix.** Optional `setOperator(addr, bool resetAnchor)` overload; when `resetAnchor=true`, zero `_updatedAt` so the next push is exempt.

### L2: `OracleRouter.setFeed` does not atomically enforce that `setMaxStaleness` has been called

- **Severity:** LOW
- **Confidence:** 100
- **Affected:** `src/core/oracle/OracleRouter.sol:47-52`, `:80-82`
- **PoC status:** NOT_BUILT

`setFeed(asset, addr)` writes the feed pointer without touching `_maxStaleness`. A freshly-registered asset returns `(0, false)` from `tryGetUsdValue` until governance calls `setMaxStaleness`. This is fail-closed (safe) but operationally surprising.

**Recommended fix.** Either combine `setFeed(asset, addr, maxStaleness)` into one atomic call, or assert `_maxStaleness[asset] != 0` at `setFeed` time.

### L3: `PushOracle` first-push freedom + `_minPrice=1` default lets the operator anchor at any value on first deploy

- **Severity:** LOW
- **Confidence:** 95
- **Affected:** `src/core/oracle/PushOracle.sol:62-75`, `:84`
- **PoC status:** NOT_BUILT

The first `setPrice` after deploy is exempt from the deviation guard (line 84). Combined with `_minPrice=1` and `_maxPrice=type(uint256).max` defaults, the first push can be any value. Subsequent pushes are bounded to ±50% of the first push — so a fat-fingered first push locks the oracle into a wrong neighborhood until governance widens deviation.

**Recommended fix.** Push the initial price *atomically* with `setFeed` and `setBounds` in the same deploy transaction.

---

## INFO

### I1: `_interestWithDayCount` deducts one day of interest from every loan (`days_ = rawDays - 1`)

- **Severity:** INFO
- **Confidence:** 100
- **Affected:** `src/core/centuari/Centuari.sol:365-373`

Documented behavior: comment at line 359 says "start+1 = day 1, maturity-1 = last day". A 1-day loan earns 0 interest; a 30-day loan earns 29 days' interest. Not a bug; flagged because the off-chain matcher and the bond-token name (e.g., "CBT USDC 1 Jan 2025") may give users a different intuition.

### I2: `_marketLoanToken[marketId]` is set on first settlement but never validated against operator's later input — non-canonical marketIds remain stable but inconsistent

- **Severity:** INFO
- **Confidence:** 99
- **Affected:** `src/core/centuari/Centuari.sol:127-129` (settlement set-once); `:589-613` (seedBorrowerMarkets re-writes)

Operator-trust dependent; not exploitable externally. The set-once pattern at lines 127-129 means the first settlement's `loanToken` "wins" for that marketId. `seedBorrowerMarkets` (line 609) unconditionally overwrites without checking the prior value. Documented at INVARIANTS C-2 / S-4 / ARCHITECTURE notable choice #2.

### I3: Slither flagged "reentrancy-no-eth" in `settleMatch` and `withdrawLendPosition` — verified safe

- **Severity:** INFO
- **Confidence:** 100
- **Affected:** Slither outputs in `slither-high-impact.txt`

The external calls before state writes (`factory.getOrCreate`, `bondToken.burn`) target contracts that do not call out (CREATE2 deploys with no constructor side-effects; ERC20 burn has no hooks). Cross-function reentry is blocked by Centuari's `nonReentrant` guard. Flagged but not exploitable.

### I4: BalanceLedger storage gap comment is off-by-one

- **Severity:** INFO
- **Confidence:** 100
- **Affected:** `src/core/balance-ledger/BalanceLedgerStorage.sol:127-131`

Comment says "Current usage: 9 slots", actual layout is 8 slots (the two booleans pack into one slot, not two). `__gap[41]` is correct sized vs the actual 8 slots used (8+41=49). Pure doc nit; CI catches drift on upgrades.

### I5: HF formula's atypical conservatism — Centuari's HF approaches `(X-1)·weightedLTV` for X=collateralization-ratio

- **Severity:** INFO
- **Confidence:** 100
- **Affected:** `src/core/risk/RiskModule.sol:225-228`

The non-standard formula `hf = (1 - debtUsd/collateralUsd) · weightedLTV` is documented at ARCHITECTURE.md "Notable design choices #3". It requires ≥ 2.0x collateralization at LTV=100%, ≥ 2.43x at LTV=70%, ≥ 3.0x at LTV=50% to reach HF=1.0. Conservative but consistent.

**Note on a Phase 4 agent claim:** the RiskModule vuln-hunter agent (F-1) argued this makes `canWithdraw`/`canUnflag` permanently fail for debt-carrying users. That conclusion is **mathematically incorrect** — the agent assumed `hf ≤ weightedLTV`, but `hf` actually grows linearly with collateralization ratio (`hf = (X-1) · weightedLTV` for X = collateralUsd/debtUsd). Withdrawal is achievable for sufficiently over-collateralized positions. Rejecting this agent finding.

---

## REJECTED (with proof)

### R1: RiskModule `canWithdraw`/`canUnflag` impossible for debt-carrying users

- **Rejection type:** Math falsifier (see I5 above).
- The Phase 4 RiskModule agent claimed `hf` is asymptotically bounded by `weightedLTV ≤ 1.0`, making the `1+buffer` threshold unreachable. Direct substitution into the code's `mulDiv` chain shows `hf = (X-1) · weightedLTV` where `X = collateralUsd/debtUsd`. For X = 3 and weightedLTV = 0.5 (i.e., LTV=50%), `hf = 1.0`. The formula is conservative, not impossible.

### R2: `setBondTokenFactory` allows owner to swap to malicious factory

- **Rejection type:** Bounty falsifier (owner is trusted, timelock'd in prod).
- Owner is explicitly listed as a trusted role in the threat model. The 24h ops timelock + 48h upgrade timelock + multisig together mitigate.

### R3: Operator-driven non-canonical marketId at settlement

- **Rejection type:** Bounty falsifier (operator trusted).
- Documented at INVARIANTS C-2 / S-4 / ARCHITECTURE notable choice #2. Operator can produce non-canonical settlements but the protocol's invariants only diverge if the operator misbehaves — a documented trust boundary.

### R4: CentuariBondERC20 transferability lets attackers steal CBT

- **Rejection type:** Code-path falsifier.
- Centuari only mints CBT to itself (`address(this)` at `Centuari.sol:191`). No protocol flow ever transfers CBT out of Centuari to external addresses. Centuari's CBT balance is solely owned by Centuari. ERC20 transfers between external parties (if any) don't affect Centuari's holdings.

### R5: ReentrancyGuard storage collision in proxy upgrade

- **Rejection type:** Code-path falsifier.
- `ReentrancyGuardUpgradeable.sol` uses ERC7201 namespaced storage at a specific slot derived from `keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))`. Collision-safe by design.

### R6: BalanceLedger writer-set abuse

- **Rejection type:** Bounty falsifier (owner is trusted; 48h timelock).
- Adding a malicious writer requires owner action through the 48h `proposeAuthorizedWriter`/`executeAuthorizedWriter` flow. Adding via `forceAddWriter` requires `_forceWriterRegistrationEnabled = true` at init (testnet only). Mainnet sets `false`, making force-add impossible.

### R7: HF math overflow / extreme decimal interactions

- **Rejection type:** Math falsifier (Math.mulDiv 512-bit intermediates).
- `Math.mulDiv` handles 512-bit intermediates so HF math doesn't overflow until final result exceeds uint256. Token decimals capped at 36 by `OracleRouter.MAX_TOKEN_DECIMALS`.

### R8: Borrower drives MAX_DEBT_MARKETS gas DoS

- **Rejection type:** Code-path falsifier (M2 fix at commit 18a9a64 caps via `_borrowerMarkets[borrower].length() >= MAX_DEBT_MARKETS revert`).
- Already mitigated. Cross-checked at `Centuari.sol:161` and `:606-607` (seedBorrowerMarkets).
