# [HIGH] `ChainlinkPriceFeed` missing min/maxAnswer circuit-breaker check

## Bounty Platform Submission Info
- **Target:** `src/core/oracle/ChainlinkPriceFeed.sol`
- **Severity Level:** High
- **Bug Classification:** Oracle integration footgun / insolvency-class risk on mainnet rollout

## Summary
The Chainlink adapter validates round completeness, answer positivity, and (on L2) sequencer-uptime, but never reads the underlying aggregator's `minAnswer`/`maxAnswer` circuit-breaker bounds. When a real price moves outside those bounds, Chainlink returns the clamped value; the adapter passes it through as authoritative, and downstream `RiskModule` and `LiquidationEngine` consume the clamped USD value as if it were the real price.

This is the canonical "Venus/LUNA May 2022" class of bug. It is dormant on Arbitrum Sepolia (the project explicitly states all assets currently use `PushOracle`), but is in scope for this audit because the contract gates the mainnet rollout: any mainnet asset wired through `setFeed` immediately exposes this bug.

## Detail
- **Contract:** `src/core/oracle/ChainlinkPriceFeed.sol`
- **Function:** `latestPriceUsd`
- **Lines:** 58-66
- **Category:** Oracle integration (missing circuit-breaker check)
- **Root cause:** The vendored `AggregatorV3Interface` exposes only `decimals()` and `latestRoundData()`. The underlying `AccessControlledOffchainAggregator` exposes `aggregator()`, which in turn exposes `minAnswer()` and `maxAnswer()`. The adapter never calls these.

Verified by `grep -rn "minAnswer\|maxAnswer" src/` (no matches) and direct read of `src/interfaces/external/AggregatorV3Interface.sol` (only 2 functions).

## Impact
Direct precedent: in May 2022, the Venus protocol on BSC paid out approximately $11M of bad debt when LUNA crashed past its Chainlink `minAnswer` of $0.10 (while real price was below $0.01). The protocol's borrowers saw their LUNA collateral over-valued by 10x, borrowed against the inflated value, and walked away when the feed eventually unclamped.

For Centuari, the symmetric scenarios are:
- **Collateral over-valued at min clamp.** A flagged collateral asset whose real price has collapsed but Chainlink reports the floor. Borrower's HF stays healthy on-chain → no liquidation. Borrower withdraws (`canWithdraw` returns true), real reserve loss when Chainlink eventually catches up.
- **Debt under-valued at min clamp.** A loan token whose real price crashed but Chainlink clamps it. RiskModule sees small `debtUsd` and treats borrower as healthy. They can keep borrowing or withdrawing collateral at HF that does not reflect reality.
- **Collateral under-valued at max clamp.** Unjust liquidations against an artificially-low collateral price (borrower loses bonus on collateral they should still own).

Magnitude scales with TVL on the affected token at mainnet.

## Step-by-Step Exploitation
Conceptual (a passing PoC requires a Chainlink fork, deferred to mainnet pre-deploy testing):
1. Wait for or trigger a black-swan price move past `minAnswer` on a Chainlink-feed-priced collateral asset.
2. Chainlink reports the clamped value; `ChainlinkPriceFeed.latestPriceUsd` passes it through as authoritative.
3. Borrow against the over-valued collateral; withdraw real loan tokens; abandon position.
4. Realised loss = (real collateral value at clamp - clamped value).

## Proof of Concept

Not built. The exploit requires either:
- A mainnet-fork test that pins to a historical date when an asset hit its Chainlink bound (e.g., LUNA's May 2022 collapse on Polygon Mainnet), OR
- A mock aggregator that returns `minAnswer` regardless of real-world price (trivial; ~30 LoC), wired into `OracleRouter` and then a borrow→withdraw flow on Centuari/LiquidationEngine.

The pattern itself is industry-known and the rejection-with-proof for "this is a real bug" is the absence of any code in `ChainlinkPriceFeed.sol` that reads min/max bounds.

## Recommended Fix

Read the underlying aggregator's min/max bounds at construction (immutable per phase), then fail-closed when `answer` hits the rails:

```solidity
import "...AccessControlledOffchainAggregator.sol";

contract ChainlinkPriceFeed is IPriceFeed {
    // ... existing immutables ...
    int192 public immutable MIN_ANSWER;
    int192 public immutable MAX_ANSWER;

    constructor(address aggregator_, address sequencerUptimeFeed_) {
        if (aggregator_ == address(0)) revert ZeroAddress();
        AGGREGATOR = AggregatorV3Interface(aggregator_);
        FEED_DECIMALS = AggregatorV3Interface(aggregator_).decimals();
        SEQUENCER_UPTIME_FEED = AggregatorV3Interface(sequencerUptimeFeed_);

        // SC-4 hardening: read circuit-breaker bounds from the underlying aggregator.
        address underlying = AggregatorProxyInterface(aggregator_).aggregator();
        MIN_ANSWER = AccessControlledOffchainAggregator(underlying).minAnswer();
        MAX_ANSWER = AccessControlledOffchainAggregator(underlying).maxAnswer();
    }

    function latestPriceUsd() external view returns (uint256 price1e18, uint256 updatedAt) {
        // ... existing checks ...
        if (answer <= MIN_ANSWER || answer >= MAX_ANSWER) return (0, updatedAt_);
        // ... rest of conversion ...
    }
}
```

The "strict less-than/greater-than" form is intentional — Chainlink reports `==minAnswer` when the real price is at-or-below the floor. Treating equality as clamped is the conservative reading.

If `aggregator()` is not available on all aggregator deployments (e.g., the proxy phase rotation breaks this), an alternative is a per-asset `setBounds(min, max)` governance call on `OracleRouter` that applies after the feed's USD value is computed.

## References
- Venus / LUNA, May 2022: https://rekt.news/venus-rekt/ (~$11M lost).
- Synthetix sUSD / Compound / Aave have all shipped or retrofitted this check.
- This issue is dormant on Sepolia (PushOracle in use) per `ChainlinkPriceFeed.sol:18` NatSpec, but Centuari's stated `mainnet rollout` will wire Chainlink feeds.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | High |
| `confidence_0_100` | 95 |
| `single_strongest_reject` | "Dormant on Sepolia." — countered: the audit instruction explicitly includes ChainlinkPriceFeed and the file is documented as the mainnet path. |
| `smallest_falsifier` | grep for `minAnswer\|maxAnswer` in `src/` (zero matches confirms). |
| `gate_failures` | none |
| `poc_status` | NOT_BUILT (industry-standard pattern; PoC pre-mainnet deploy recommended) |
