# [INFO] `BalanceLedgerStorage` `__gap` comment under-counts used slots

## Target
`src/core/balance-ledger/BalanceLedgerStorage.sol:127-131`.

## Summary
The doc comment says "Current usage: 2 bool slots + 3 balance/writer mappings + 3 collateral mappings + _pauser = 9 slots." But `_paused` and `_forceWriterRegistrationEnabled` pack into one slot, not two. Actual layout (per snapshot CI) is 8 slots used + 41-slot gap = 49 total within the 50-slot budget. Pure documentation nit; CI catches drift on upgrades.

## Recommended Action
Update the comment to reflect 8 actual slots ("1 packed-bool slot + 3 balance/writer mappings + 3 collateral mappings + _pauser = 8 slots").

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Informational |
| `confidence_0_100` | 100 |
| `gate_failures` | none |
