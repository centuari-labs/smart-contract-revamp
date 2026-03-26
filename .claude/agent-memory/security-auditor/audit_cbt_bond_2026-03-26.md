---
name: CBT Bond Token Audit 2026-03-26
description: Targeted audit of CentuariBondERC20.sol, CentuariBondERC20Factory.sol, CBT redemption in CentuariEndpoint, and related bond token contracts. 0 CRITICAL, 1 HIGH, 2 MEDIUM, 4 LOW, 5 INFO. VERDICT: REQUEST CHANGES.
type: project
---

## Audit: CBT Bond Token Contracts — 2026-03-26

### Contracts Reviewed
- src/core/centuari/CentuariBondERC20.sol (143 lines)
- src/core/centuari/CentuariBondERC20Factory.sol (246 lines)
- src/core/CentuariEndpoint.sol (lines 257-319 rollovers/refinances, lines 537-565 redeemCBT)
- src/core/CentuariEndpointStorage.sol (79 lines)
- src/libraries/DateTime.sol (176 lines)
- src/interfaces/ICBT.sol (71 lines)
- src/core/pcbt/PCBTVault.sol (326 lines, admin setters only)

### Findings Summary
- CRITICAL: 0
- HIGH: 1
- MEDIUM: 2
- LOW: 4
- INFO: 5

### HIGH

**H-01: Refinance anchor rate bypass (Invariant #15 FAIL)**
- CentuariEndpoint._processRefinances line 312: `if (r.anchorRateBPS > 0)` is conditional
- CentuariEndpoint._processRollovers line 269: `require(r.anchorRateBPS > 0)` is unconditional
- Engine can submit anchorRateBPS=0 for refinances, bypassing the +/-50 bps anchor bound
- This is the SAME bug flagged in multiple prior audits (cross_function, arithmetic_oracle, final_preaudit)
- **Why:** Incomplete fix propagation -- rollovers were fixed but refinances were not
- **How to apply:** This pattern recurs. Always check BOTH rollover and refinance code paths when fixing one.

### MEDIUM

**M-01: redeemCBT does not validate cbtAddress is factory-deployed**
- CentuariEndpoint.redeemCBT (line 537) accepts any address as cbtAddress
- Attacker deploys fake CBT with matching interface, calls redeemCBT to drain BalanceLedger underlying
- Fix: validate via `require(IBondTokenFactory(_bondTokenFactory).bondTokens(marketId) == cbtAddress)`

**M-02: Public burn(uint256) allows permanent fund loss**
- CentuariBondERC20 line 76: `burn(uint256)` is public, anyone can burn their own CBT
- Burns CBT without returning underlying -- permanent value destruction
- Fix: Remove public burn(uint256) or add a warning NatSpec. Users should use redeemCBT instead.

### LOW
- L-01: Factory getOrCreate lacks validation (loanToken != address(0), maturity > block.timestamp)
- L-02: Factory decimal fallback to 18 for tokens without decimals() could cause wrong CBT precision
- L-03: PCBTVault admin setters (setWithdrawalCutoff, setNextMaturity, setCurrentCBT) lack timelock
- L-04: redeemCBT blocked when paused (tension with Invariant #21 -- users should withdraw available when paused)

### INFO
- I-01: ReentrancyGuard inherited but unused in CentuariBondERC20 (redeem/redeemTo are pure reverts)
- I-02: Dead code: event Redeemed (line 137), error ZeroAddress (line 142) in CentuariBondERC20
- I-03: ICBT interface declares errors (NotYetMatured, InsufficientBalance, etc.) not used in implementation
- I-04: ERC20 compliance confirmed good -- transfer, approve, allowance all correct via OpenZeppelin
- I-05: CREATE2 deployment via factory confirmed sound -- marketId as salt prevents collisions

### Invariant Check
- Invariant #15 (Anchor rate bounds): **FAIL** -- refinance bypass via conditional check
- All other invariants: PASS for CBT-related scope

### Recurring Patterns Confirmed
- Pattern #1: Incomplete fix propagation (anchor rate fixed for rollovers, not refinances)
- This is the 4th+ audit flagging the refinance anchor bypass

### VERDICT: REQUEST CHANGES (H-01 must be fixed)
