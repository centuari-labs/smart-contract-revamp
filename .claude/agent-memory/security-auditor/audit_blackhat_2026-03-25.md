---
name: Black Hat Audit 2026-03-25
description: Adversarial exploit-focused audit of all core contracts. 3 CRITICAL, 5 HIGH, 4 MEDIUM findings. Key exploits: LiquidationEngine decimal mismatch (repeated collateral drain), CBT redemption pool shared with user deposits, instant admin setters bypassing timelocks.
type: project
---

## Black Hat Audit — 2026-03-25

### CRITICAL findings (3):
1. **LiquidationEngine decimal mismatch** (LiquidationEngine.sol:139-140): `debtToCover` passed to RiskModule in raw token decimals (6 for USDC) but debt tracker stores 18-decimal. Liquidation barely reduces debt, position stays liquidatable indefinitely for repeated collateral extraction.
2. **CBT redemption drains user deposits** (CentuariEndpoint.sol:522, BalanceLedger.sol:296-304): `transferOut()` sends ERC20 from shared pool without deducting from any accounting entry. Redemptions compete with withdrawals.
3. **Unbacked credit via ReturnSettlement** (CentuariEndpoint.sol:360-369): Engine can credit arbitrary amounts without corresponding token inflow. Mitigated by HSM requirement but no on-chain defense.

### HIGH findings (5):
4. Instant `setRiskModule` on BalanceLedger (line 356-358) — disables HF checks
5. Rollover anchor rate bypass when `anchorRateBPS = 0` (CentuariEndpoint.sol:259)
6. Refinance only records debt delta when newPrincipal > oldDebt (line 313)
7. Grace period keyed on (borrower, debtAsset), not per-user (LiquidationEngine.sol:85)
8. Instant `setBalanceLedger` and `setAssetBehaviorRegistry` on RiskModule and BalanceLedger

### MEDIUM findings (4):
9. Collateral array unbounded growth (gas griefing)
10. YieldRouter.verifyReserveRatio() is a no-op (returns true always)
11. LiquidationEngine.setAuthorizedCaller() instant (no timelock)
12. HubIntentSettler credits `amount` not `received` (fee-on-transfer risk)

### Key patterns:
- Decimal normalization is inconsistent between CentuariEndpoint (normalizes) and LiquidationEngine (doesn't)
- Admin setters on BalanceLedger and RiskModule lack timelocks despite CentuariEndpoint having them
- No on-chain accounting invariant enforcement (CBT supply vs token balance)

**Why:** These findings demonstrate the protocol is not yet safe for mainnet. The decimal mismatch alone enables complete collateral drain.
**How to apply:** Block merge until all CRITICAL and HIGH findings are fixed. The decimal mismatch is the highest priority fix.
