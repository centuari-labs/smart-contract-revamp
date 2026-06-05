# [INFO] Pre-upgrade borrowers with > 64 debt markets cannot be fully reconciled by `seedBorrowerMarkets`

## Target
`src/core/centuari/Centuari.sol:589-613` (`seedBorrowerMarkets`, M2-hardened with MAX_DEBT_MARKETS cap).

## Summary
`seedBorrowerMarkets` reconciles a borrower's `_borrowerMarkets` set with their pre-existing `_borrowDebt` entries. After the M2 hardening (commit 18a9a64), the function enforces the same `MAX_DEBT_MARKETS = 64` cap as `settleMatch`. If any borrower had > 64 distinct debt markets BEFORE the Phase 3 (C6) upgrade introduced enumeration, only the first 64 will be reconcilable; the remaining debt markets are *invisible* to the `RiskModule` HF loop.

## Detail
This only applies if the production deployment ever had borrowers with > 64 debt markets pre-upgrade. For a fresh deployment, this is N/A. For ongoing testnet operation, it depends on whether any borrower's pre-upgrade state exceeded 64 markets.

If yes:
- `getBorrowerDebts(user)` enumerates only the 64 reconciled markets.
- RiskModule sums debt across only those 64.
- The remaining debt is "free" — does not factor into HF.
- The borrower's HF reads as healthier than reality; they can withdraw / unflag against under-stated debt.

## Recommended Action
1. Run a pre-deployment query: for every existing borrower, count distinct `_borrowDebt[mid][borrower] > 0` markets.
2. If any borrower exceeds 64, plan a migration: either close some markets via `Centuari.repay` to bring them under cap, OR raise `MAX_DEBT_MARKETS` (a storage-layout-safe change at the constant level — careful with gas).
3. If all borrowers are <= 64, document this as a deploy-time invariant going forward (the on-chain cap already enforces it post-upgrade).

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Informational |
| `confidence_0_100` | 90 |
| `gate_failures` | none |
| `poc_status` | N/A (state-dependent) |
