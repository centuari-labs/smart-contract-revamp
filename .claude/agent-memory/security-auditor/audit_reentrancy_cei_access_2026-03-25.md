---
name: Reentrancy CEI and Access Control Audit 2026-03-25
description: Focused audit of all 40 contracts in src/core/ and src/spoke/ for reentrancy safety, CEI pattern compliance, and access control correctness. 10 HIGH (instant admin setters), 8 MEDIUM (missing nonReentrant, instant non-critical setters).
type: project
---

## Audit Scope
All 40 Solidity files in src/core/ and src/spoke/. Focused on reentrancy, CEI pattern, and access control.

## Key Findings

### Systemic Pattern: Instant Admin Setters (10 HIGH)
Every contract EXCEPT CentuariEndpoint, AssetBehaviorRegistry, CentuariRateOracle, FeeController, and CentuariRouter has at least one critical admin setter without a 48h timelock.

Most dangerous:
- RiskModule.setBalanceLedger() — redirects HF computation
- BalanceLedger.setRiskModule() — disables withdrawal safety
- SpokeVaultRWA.setLayerZeroEndpoint/setHubLiquidationEngine — drains all RWA collateral
- LiquidationEngine.setAuthorizedCaller() — arbitrary debt manipulation
- CollateralRegistry.setLayerZeroReceiver() — fake attestation injection

### Missing nonReentrant (3 MEDIUM)
- YieldRouter.depositToReserve()
- SpokeVaultRWA.lzReceive()
- SpokeVaultStable.receiveFromHub()

### CEI Generally Followed
The codebase follows CEI well. nonReentrant on outer functions provides strong defense even where ordering is imperfect within internal functions.

**Why:** A single compromised owner key can drain the protocol via instant admin setters.
**How to apply:** All setXxx() controlling security-critical addresses must use propose/apply 48h timelock pattern already present in CentuariEndpoint.
