---
name: audit_abr_cr_2026-03-26
description: Security audit of AssetBehaviorRegistry.sol, CollateralRegistry.sol, RiskModule.sol, LiquidationEngine.sol — 1 CRITICAL (LTV overwrite), 1 HIGH (ghost liquidator whitelist), 7 MEDIUM, 1 LOW. VERDICT: REQUEST CHANGES.
type: project
---

## Audit: AssetBehaviorRegistry + CollateralRegistry (2026-03-26)

**Contracts:** AssetBehaviorRegistry.sol (292 lines), CollateralRegistry.sol (379 lines), RiskModule.sol (489 lines), LiquidationEngine.sol (370 lines)

**VERDICT:** REQUEST CHANGES

### Findings Summary
- **1 CRITICAL:** updateAsset() at line 127 overwrites LTV immediately via full struct assignment, breaking discrete governance model. _pendingLTVChanges created but never consulted by getEffectiveLiqThreshold/getEffectiveMaxLTV.
- **1 HIGH:** removeLiquidator() at line 187 sets mapping false but leaves ghost entry in _liquidatorList array. After add+remove of all liquidators, isLiquidatorApproved returns false for everyone, permanently blocking liquidations.
- **7 MEDIUM:** feedDecimals>18 underflow (CR:143), pCBT no staleness (CR:112), processAttestation no asset validation (CR:66), debt ceiling raw amounts (RM:129), no asset class validation (ABR:286), setSpokeVaultRWA no timelock (LE:339), supplyCap not enforced.
- **1 LOW:** setSequencerUptimeFeed no timelock (RM:386).

### Key Patterns
- Instant admin setters continue to appear (setSpokeVaultRWA, setSequencerUptimeFeed)
- Struct-level assignment overwriting governance-protected fields is a new pattern
- Ghost array entries after removal is a classic Solidity footgun

**Why:** These are pre-mainnet blocking issues. C-01 enables mass liquidation of healthy positions. H-01 can permanently freeze liquidations for RWA assets.

**How to apply:** C-01 and H-01 must be verified fixed before any subsequent audit passes these contracts.
