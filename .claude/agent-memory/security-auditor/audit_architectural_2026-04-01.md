---
name: Architectural Settlement Layer Audit 2026-04-01
description: Deep architectural audit of 10 settlement layer files across old and new architectures. 2 CRITICAL (processReturns unbacked credits, dual state stores), 5 HIGH, 5 MEDIUM. VERDICT: REQUEST CHANGES.
type: project
---

## Architectural Settlement Layer Audit — 2026-04-01

**Scope**: 10 files — CentuariEndpoint, BalanceLedger, FeeController, Treasury, Settlement, Centuari, and their storage/interface contracts.

**Focus areas**: Dual architecture risk, atomic settlement, BalanceLedger write access, CBT mint/burn via low-level call, nonce replay, fee controller integration, upgrade safety.

### Findings Summary
- 2 CRITICAL: D-02 (processReturns credits balance without token movement/CBT burn), A-01 (two independent state stores with no sync)
- 5 HIGH: A-02 (old arch no HSM sig), A-03/G-02 (Treasury non-upgradeable), D-01 (CBT mint skipped when factory unset), G-03 (old arch no timelocks)
- 5 MEDIUM: B-02/F-01 (FeeController blocks batch), C-02 (old arch operator drain), E-01 (strict nonce equality), E-02 (old arch no nonce)
- 1 LOW: F-02 (fee skip when controller unset)
- 4 PASS: B-01 (atomicity), C-01 (Invariant #9), G-01 (storage gaps), G-04 (new arch timelocks)

### Recurring Patterns Confirmed
- processReturns unbacked credits: confirmed AGAIN (first flagged in audit_mainnet_settlement_2026-04-01.md)
- Old architecture instant admin setters: confirmed AGAIN (flagged multiple times)
- Treasury operator instant setter: confirmed AGAIN

**Why:** This was the first audit to deeply examine both old and new architectures as a single attack surface.

**How to apply:** Any migration plan must address the dual state store risk. processReturns remains the #1 CRITICAL across all audits.

VERDICT: REQUEST CHANGES
