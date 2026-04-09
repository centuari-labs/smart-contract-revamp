---
name: Mainnet Settlement Layer Audit 2026-04-01
description: Mainnet-grade security audit of CentuariEndpoint, CBT, Factory, and settlement math. 1 CRITICAL, 2 HIGH, 5 MEDIUM, 4 LOW, 6 INFO.
type: project
---

# Mainnet Settlement Layer Audit - 2026-04-01

## Scope
- CentuariEndpoint.sol (585 lines)
- CentuariEndpointStorage.sol (79 lines)
- CentuariBondERC20.sol (145 lines)
- CentuariBondERC20Factory.sol (244 lines)
- ICentuariEndpoint.sol (196 lines)
- ICBT.sol (72 lines)
- Supporting: BalanceLedger.sol, RiskModule.sol, LiquidationEngine.sol

## Findings Summary
- CRITICAL: 1
- HIGH: 2
- MEDIUM: 5
- LOW: 4
- INFO: 6

## Key Issues
- C-01: _processReturns credits unbacked tokens (no burn/source verification)
- H-01: Rollover uses block.timestamp not matchTimestamp for CBT validation
- H-02: Refinance only records debt DELTA, not full replacement tracking
