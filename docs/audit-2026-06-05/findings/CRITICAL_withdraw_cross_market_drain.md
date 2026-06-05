# [CRITICAL] Cross-market drain via mismatched (marketId, loanToken, maturity) in `withdrawLendPosition`

## Bounty Platform Submission Info
- **Target:** `src/core/centuari/Centuari.sol`
- **Target Description:** Centuari core lending contract (upgradeable, ERC1967 proxy)
- **Severity Level:** Critical
- **Bug Classification:** Theft of user / protocol funds (direct, permissionless)

## Summary
`Centuari.withdrawLendPosition` validates the caller's CBT position against the operator-supplied `marketId`, but resolves the bond token and credits the redeemed amount from the caller-supplied `(loanToken, maturity)` pair. The two are never tied together. Any lender holding a CBT position at any market can drain the bond-token supply of any *other* matured market, receiving the other market's loan token and locking the legitimate lenders of that market out of redemption.

## Detail
- **Contract:** `src/core/centuari/Centuari.sol`
- **Function:** `withdrawLendPosition(bytes32 marketId, address loanToken, uint256 maturity, uint256 cbtAmount)`
- **Lines:** 329-357
- **Category:** Logic error / accounting integrity / parameter cross-validation missing
- **Root cause:** four pieces of input that *must* describe the same market are accepted independently. The bond-token lookup uses `(loanToken, maturity)`. The position-existence and supply checks use `marketId`. The credit uses `loanToken`. No validator asserts `marketId == keccak256(abi.encode(loanToken, maturity))`, and no validator asserts `_marketLoanToken[marketId] == loanToken`.
- **Affected code (verbatim):**

```solidity
// Centuari.sol:329-357
function withdrawLendPosition(bytes32 marketId, address loanToken, uint256 maturity, uint256 cbtAmount)
    external
    whenNotPaused
    nonReentrant
{
    if (cbtAmount == 0) revert InvalidAmount();
    if (_bondTokenFactory == address(0)) revert BondTokenNotFound();

    address bondToken = CentuariBondERC20Factory(_bondTokenFactory).getBondToken(loanToken, maturity); // (1)
    if (bondToken == address(0)) revert BondTokenNotFound();

    if (block.timestamp < maturity) revert NotYetMatured();                                              // (2)

    if (_lendPositionCbtAmount[marketId][msg.sender] < cbtAmount) {                                      // (3)
        revert InvalidAmount();
    }
    if (_marketTotalCbt[marketId] < cbtAmount) revert InvalidAmount();                                   // (3)

    CentuariBondERC20(bondToken).burn(cbtAmount);                                                        // (4) burns from (1)

    _lendPositionCbtAmount[marketId][msg.sender] -= cbtAmount;                                           // (5)
    _marketTotalCbt[marketId] -= cbtAmount;                                                              // (5)

    IBalanceLedger(_balanceLedger).credit(msg.sender, loanToken, cbtAmount);                             // (6) credits caller-supplied token

    emit LendPositionWithdrawn(marketId, msg.sender, cbtAmount, cbtAmount);
}
```

(1)/(4) operate on the canonical bond for `(loanToken, maturity)`. (3)/(5) operate on the operator-supplied `marketId`. (6) credits the caller-supplied `loanToken`. Any inconsistency between the three groups goes uncaught.

## Impact
**Direct, permissionless theft.** A lender that legitimately deposited and lent `X` units of `tokenA` into market A can withdraw `X` units of `tokenB` from market B's bond-token reserve, provided:
1. The caller has `_lendPositionCbtAmount[marketId_A][caller] >= cbtAmount`.
2. `_marketTotalCbt[marketId_A] >= cbtAmount`.
3. `bondToken_for_(tokenB, maturity_B)` exists and Centuari holds `>= cbtAmount` of it.
4. `block.timestamp >= maturity_B`.

The caller's own market (A) is **not** affected: the bond burn goes to `bondToken_B`, not `bondToken_A`. So the attacker keeps their original position's bond supply intact while siphoning B's.

**Aggregate impact.** Lenders in market A collectively hold `_marketTotalCbt[A]` CBT. They can drain `_marketTotalCbt[A]` worth of any other market's loan token — picking whichever token has appreciated since their settlement OR whichever market has matured first. Combined with the early-redemption variant (see PoC #2), every lender effectively redeems at the FIRST maturity of any market in the protocol regardless of their own tenor.

**Knock-on damage.** The drained market's legitimate lenders cannot redeem: `bondToken.burn` reverts on `ERC20InsufficientBalance`. Their CBT becomes worthless until governance manually re-mints (no on-chain path exists).

## Step-by-Step Exploitation
1. Identify any matured market B in the protocol where Centuari still holds bond-token supply (legitimate B lenders have not yet all redeemed). The matched loan token of B is the token the attacker will receive.
2. Hold (or acquire) ANY non-zero `_lendPositionCbtAmount[mid_X][attacker]` position, where `mid_X` may be any marketId at all (even one that has not yet matured).
3. Call `Centuari.withdrawLendPosition(mid_X, tokenB, maturity_B, cbtAmount)` where `cbtAmount <= _lendPositionCbtAmount[mid_X][attacker]`.
4. The function burns `cbtAmount` of `bondToken_B` from Centuari's custody and credits `cbtAmount` of `tokenB` to the attacker in `BalanceLedger`.
5. Attacker may then withdraw `tokenB` via the protocol's normal withdrawal path.
6. Result: attacker gains `cbtAmount` of `tokenB`, protocol loses `cbtAmount` of `tokenB` reserves. Market B's legitimate lenders' redemption reverts.

## Proof of Concept

Two passing Foundry tests at `test/exploits/centuari-2026-06-05/WithdrawCrossMarketDrain.t.sol`:
- `testExploit_CrossMarketWithdrawDrains` — attacker swaps USDC position for DAI from a different market.
- `testExploit_EarlyWithdrawViaShorterMaturityMarket` — attacker uses a 1-year USDC position to redeem from a 1-day USDC market 364 days early.

### How to Run
```bash
forge test --match-path "test/exploits/centuari-2026-06-05/WithdrawCrossMarketDrain.t.sol" -vv
```

### Test Output
```
Ran 2 tests for test/exploits/centuari-2026-06-05/WithdrawCrossMarketDrain.t.sol:WithdrawCrossMarketDrain
[PASS] testExploit_CrossMarketWithdrawDrains() (gas: 1718293)
Logs:
  === EXPLOIT SUMMARY ===
  Attacker lent USDC, withdrew DAI.
  Victim's legitimate DAI withdrawal now reverts.

[PASS] testExploit_EarlyWithdrawViaShorterMaturityMarket() (gas: 1698534)
Logs:
  === EARLY WITHDRAW SUMMARY ===
  Attacker withdrew their long-dated position via the short market's supply, 364 days early.

Suite result: ok. 2 passed; 0 failed; 0 skipped; finished in 8.10ms
```

## Recommended Fix
Add a single explicit consistency check at the top of `withdrawLendPosition`. Equivalent options:

**Option A (minimal diff, preserve signature):**
```solidity
function withdrawLendPosition(bytes32 marketId, address loanToken, uint256 maturity, uint256 cbtAmount)
    external
    whenNotPaused
    nonReentrant
{
    if (cbtAmount == 0) revert InvalidAmount();
    if (marketId != _getMarketId(loanToken, maturity)) revert InvalidAmount(); // <-- ADD
    ...
}
```

**Option B (preferred, by-construction safety):** drop the redundant `marketId` parameter from the interface and derive it locally. Then the caller cannot pass a mismatched tuple:
```solidity
function withdrawLendPosition(address loanToken, uint256 maturity, uint256 cbtAmount) external whenNotPaused nonReentrant {
    bytes32 marketId = _getMarketId(loanToken, maturity);
    ...
}
```

Either fix shuts the door entirely. Option B is preferred because it eliminates the *possibility* of operator-side and off-chain client-side mis-construction, not just the on-chain exploit.

**Defensive companion fix.** Apply the same `marketId == _getMarketId(loanToken, maturity)` assertion to `repay` and `liquidationRepay` (see M3 in CANDIDATES.md). These are gated by operator/liquidation-engine trust today, but the same one-line check turns a class of operator typos into a hard revert rather than silent accounting drift.

## References
- M2 fix in commit 18a9a64 added a similar input-bound check on `seedBorrowerMarkets`. This finding is in the same class (operator-supplied `marketId` without cross-validation) but on the caller-facing path, so the trust boundary is permissionless rather than operator-trusted.
- PoC file: `test/exploits/centuari-2026-06-05/WithdrawCrossMarketDrain.t.sol`
- Slither did not flag this (cross-parameter semantic consistency is outside its detector set).

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Critical |
| `confidence_0_100` | 99 |
| `single_strongest_reject` | "The attacker's own market's bond supply also drops" — refuted by PoC: bondA balance is unchanged after the cross-market drain (only bondB drops). |
| `smallest_falsifier` | The PoC already proves attack; absent of the fix, no falsifier exists. |
| `gate_failures` | none |
| `poc_status` | PASSING |
