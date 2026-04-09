---
name: CBT/pCBT/Router/RateOracle Deep Audit 2026-04-01
description: Architectural audit of 8 contracts (PCBTVault, CBT, Factory, RateOracle, Router, Endpoint). 3 CRITICAL (PCBTVault queue drain, Router deposit lock, Router withdraw unauth), 1 HIGH (PCBTVault instant setters), 2 MEDIUM, 3 LOW, 5 INFO.
type: project
---

## Audit: CBT Token System, pCBT Vault, Rate Oracle, CentuariRouter

**Date**: 2026-04-01
**Contracts**: PCBTVault.sol, PCBTVaultFactory.sol, PCBTVaultStorage.sol, CentuariRateOracle.sol, CentuariRouter.sol, CentuariBondERC20.sol, CentuariBondERC20Factory.sol, CentuariEndpoint.sol
**Verdict**: REQUEST CHANGES

### Findings Summary
- **3 CRITICAL**: PCBTVault._processWithdrawalQueue() burns full shares on capped USDC payout (C-01), CentuariRouter.deposit() never mints shares — funds locked (C-02), CentuariRouter.withdraw() no owner authorization check (C-03)
- **1 HIGH**: PCBTVault 3 instant admin setters without timelocks (H-01)
- **2 MEDIUM**: processReturns unbacked credits (M-01, recurring), PCBTVault cutoff underflow (M-02)
- **3 LOW**: Router self-approve, CBT public burn without guardrails, unbounded maturities array
- **5 INFO**: Factory CREATE2 collision-safe, linear pricing model documented, intent double-fill prevented, low-level .call() fixed, VIRTUAL_OFFSET inflation defense works

### 12 Focus Areas Results
All 12 user-specified focus areas assessed. Items 2-12 PASS. Item 1 (withdrawal queue drain) CRITICAL.

### Key Recurring Patterns Confirmed
1. processReturns unbacked credits — 7th+ time flagged, still present
2. Instant admin setters — PCBTVault still lacks timelocks
3. CentuariRouter ERC-4626 — broken since first identified in March 2025 fresh-eyes audit

**Why:** PCBTVault and CentuariRouter have fund-loss vulnerabilities that block mainnet deployment.
**How to apply:** C-01 requires proportional share burning when USDC payout is capped. C-02/C-03 require either full ERC-4626 implementation or removal of deposit/withdraw functions.
