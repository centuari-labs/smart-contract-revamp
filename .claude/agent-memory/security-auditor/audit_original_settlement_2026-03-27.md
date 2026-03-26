---
name: Original Settlement Architecture Audit (2026-03-27)
description: Security audit of Settlement.sol + Centuari.sol + Treasury.sol — the original settlement flow. 1 CRITICAL (Treasury fund drain), 3 HIGH, 4 MEDIUM. VERDICT: REQUEST CHANGES.
type: project
---

## Audit: Original Settlement Architecture (Settlement.sol, Centuari.sol, Treasury.sol)
**Date**: 2026-03-27
**Contracts**: Settlement.sol, Centuari.sol, Treasury.sol, SettlementStorage.sol, CentuariStorage.sol, CentuariBondERC20.sol, CentuariBondERC20Factory.sol
**Verdict**: REQUEST CHANGES

### Summary
- 1 CRITICAL: Treasury operator/admin can drain all user funds via instant `setCentuariContract()` + fake Centuari calling `settle()` to rearrange balances, then `withdraw()`.
- 3 HIGH: (1) No timelocks on any admin setter across all 3 contracts, (2) Treasury is non-upgradeable while Settlement/Centuari are upgradeable, (3) Users cannot self-repay (`repay()` is `onlyOperator`).
- 4 MEDIUM: SettlementStorage gap 51 not 50, no rate bounds validation, no timestamp staleness check, Treasury.setOperator() missing zero-check and event.
- 3 LOW, 3 INFO.

### Key Patterns
- **Instant admin setters**: 10th+ audit flagging this across Centuari contracts. Most persistent finding in codebase.
- **Operator bottleneck**: `repay()` is operator-only, creating DoS risk for all borrowers if operator goes offline.
- **Architectural mismatch**: Treasury (non-upgradeable) holds all funds but cannot be patched if a bug is found.
- **CEI compliance**: Good. All state changes occur before external calls in Settlement and Centuari.
- **Reentrancy**: Good. `nonReentrant` on all critical paths in Settlement and Centuari.

### Relation to New Architecture
The original (Settlement/Centuari/Treasury) and new (CentuariEndpoint/BalanceLedger) architectures share no state. Safe as long as not active simultaneously for same markets. Bond token factory CENTUARI immutable is a potential conflict point if shared.
