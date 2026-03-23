---
name: natspec-writer
description: >
  Invoke when adding or updating NatSpec documentation on any contract,
  function, event, or error. Centuari will be audited — documentation
  quality directly affects audit findings and cost.
allowed-tools: Read, Write, Edit, Glob
---

# Centuari NatSpec Documentation Standard

## Contract-Level

```solidity
/// @title CentuariEndpoint
/// @notice Primary settlement contract and trust anchor of the Centuari protocol
/// @dev Accepts settlement batches from the off-chain matching engine.
///      Verifies HSM ECDSA signature on every batch (Security Invariant #1).
///      Enforces strictly increasing nonce (Security Invariant #2).
///      Executes all state changes atomically.
```

Rules:
- `@title` — Contract name
- `@notice` — One sentence: what this contract does for users
- `@dev` — Multi-line: how it works, what invariants it enforces, deployment notes

## Function-Level

### Standard Function

```solidity
/// @notice Deposit tokens into the protocol
/// @dev Transfers ERC20 from caller and credits available balance in BalanceLedger.
///      Uses SafeERC20.safeTransferFrom — reverts on failed transfer.
/// @param asset The token address to deposit
/// @param amount The amount to deposit (in token's native decimals)
function deposit(address asset, uint256 amount) external {
```

### Security-Critical Function

```solidity
/// @notice Execute liquidation on an undercollateralized position
/// @dev SECURITY: Enforces multiple invariants:
///      - Invariant #11: Oracle freshness check via isPriceFresh()
///      - Invariant #18: nonReentrant modifier
///      - Grace period enforcement: reverts if grace period not expired
///      - Max 50% debt coverage per liquidation call
///      Attack surface: Flash loan griefing (mitigated by on-chain HF check).
///      Oracle manipulation (mitigated by Chainlink with maxStaleness).
/// @param borrower The address of the undercollateralized borrower
/// @param debtAsset The asset denominating the debt
/// @param debtToCover Amount of debt to repay (max 50% of total)
/// @param collateralAsset Which collateral asset the liquidator claims
function liquidate(
    address borrower,
    address debtAsset,
    uint256 debtToCover,
    address collateralAsset
) external nonReentrant {
```

### Internal/Pure Functions

```solidity
/// @notice Compute expected CBT amount using canonical seconds-based formula
/// @dev CBT_amount = principal * (1 + rateBPS * elapsedSeconds / RATE_PRECISION / SECONDS_PER_YEAR)
///      Matches architecture's BigInt formula: (principal * rateBPS * scaledTime) / 10000 / 1e9
/// @param principal The loan principal amount
/// @param rateBPS Annual rate in basis points (e.g., 800 = 8%)
/// @param matchTimestamp When the match was executed (Unix seconds)
/// @param maturity When the bond matures (Unix seconds)
/// @return The expected CBT mint amount (principal + interest)
function _computeExpectedCBT(
    uint256 principal,
    uint256 rateBPS,
    uint256 matchTimestamp,
    uint256 maturity
) internal pure returns (uint256) {
```

### View Functions

```solidity
/// @notice Get the weighted health factor for a user
/// @dev HF = sum(collateral_i_USD * liqThreshold_i) / totalDebtUSD
///      Returns type(uint256).max if user has zero debt.
///      Uses cached usdValueCached — may be stale. Call refreshCollateralValues() first.
/// @param user The user address to check
/// @return hf18 Health factor scaled by 1e18 (1e18 = HF of 1.0)
function getHealthFactor(address user) external view returns (uint256 hf18) {
```

## Events

```solidity
/// @notice Emitted when a new market is created for a (loanToken, maturity) pair
/// @param marketId The unique market identifier: keccak256(abi.encode(loanToken, maturity))
/// @param loanToken The lending asset address
/// @param maturity The maturity timestamp (Unix seconds)
event MarketCreated(bytes32 indexed marketId, address indexed loanToken, uint256 maturity);

/// @notice Emitted when a settlement batch is confirmed on-chain
/// @param nonce The batch nonce (strictly increasing)
/// @param matchCount Number of new matches processed
/// @param rolloverCount Number of rollovers processed
event SettlementBatchConfirmed(uint256 indexed nonce, uint256 matchCount, uint256 rolloverCount, ...);
```

## Custom Errors

```solidity
/// @notice Thrown when caller is not authorized to perform the action
error Unauthorized();

/// @notice Thrown when trying to replay a settlement batch with a used nonce
/// @param expected The expected next nonce
/// @param actual The nonce provided in the batch
error NonceTooLow(uint256 expected, uint256 actual);

/// @notice Thrown when the computed CBT amount does not match the submitted amount (±1 wei)
/// @param expected The on-chain computed CBT amount
/// @param actual The submitted CBT amount from the engine
error CBTMintMismatch(uint256 expected, uint256 actual);
```

## Structs

```solidity
/// @notice Represents a user's balance in the protocol
/// @dev Four sub-states track capital location:
///      available — liquid, can withdraw or place orders
///      locked — reserved for open orders (TOCTOU protection)
///      inYieldRouter — deployed to external yield protocols
///      yieldRouterShares — adapter shares for deployed capital
struct UserBalance {
    uint256 available;
    uint256 locked;
    uint256 inYieldRouter;
    uint256 yieldRouterShares;
}
```

## Rules

1. Every `external` and `public` function MUST have `@notice` and `@param` for every parameter
2. Security-critical functions MUST have `@dev` listing which invariants they enforce and what attack surface they protect against
3. Internal functions MUST have `@dev` explaining the formula or algorithm
4. Return values MUST have `@return` with units (e.g., "scaled by 1e18", "in basis points", "in token's native decimals")
5. Do NOT add NatSpec to functions you didn't modify — only document new or changed code
6. Reference invariant numbers from CLAUDE.md when relevant (e.g., "Security Invariant #11")
