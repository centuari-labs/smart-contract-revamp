---
name: Governance, Access Control & Upgradeability Audit (2026-04-01)
description: Mainnet-grade audit of AssetBehaviorRegistry, CollateralRegistry, PCBTVault, all Storage contracts, access control across ~40 contracts. 0 CRITICAL, 2 HIGH (PCBTVault instant setters, Treasury instant setOperator), 4 MEDIUM, 5 LOW. VERDICT: REQUEST CHANGES.
type: project
---

## Audit Date: 2026-04-01
## Scope: Governance, access control, upgradeability, configuration layer
## Contracts: AssetBehaviorRegistry, CollateralRegistry, PCBTVault, all 15 *Storage.sol, Treasury, Centuari, Settlement, CentuariEndpoint, BalanceLedger, RiskModule, LiquidationEngine, YieldRouter, CentuariRouter, etc.

### Findings Summary
- CRITICAL: 0
- HIGH: 2
- MEDIUM: 4
- LOW: 5
- INFO: 3

### Key outcome: PCBTVault instant admin setters remain the most dangerous gap. Treasury.setOperator() lacks timelock.
