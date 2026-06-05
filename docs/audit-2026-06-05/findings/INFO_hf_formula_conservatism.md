# [INFO] Centuari's health-factor formula is much more conservative than the industry standard

## Target
`src/core/risk/RiskModule.sol:225-228`.

## Summary
The on-chain HF formula is:
```
hf = (collateralUsd - debtUsd) * ltvWeighted / collateralUsd / debtUsd * 1e18
   = (1 - debtUsd / collateralUsd) * weightedLTV * 1e18
```
where `weightedLTV = ltvWeighted / collateralUsd = Σ (cVal_i * ltvBps_i / 1e4) / collateralUsd`.

This is **not** the standard `HF = Σ (cVal_i * ltv_i) / debtUsd`. It is much stricter:
- Standard `HF = 1.0` is reached at `collateralUsd * weightedLTV == debtUsd` (max LTV).
- Centuari `HF = 1.0` requires `collateralUsd / debtUsd >= 1 + 1/weightedLTV`.

| weightedLTV | Centuari minimum collateralization for HF=1.0 |
|-------------|-----------------------------------------------|
| 1.00 (100%) | 2.00× |
| 0.90 | 2.11× |
| 0.80 | 2.25× |
| 0.70 | 2.43× |
| 0.60 | 2.67× |
| 0.50 | 3.00× |
| 0.40 | 3.50× |
| 0.30 | 4.33× |

Combined with the default buffer of 1% (i.e., HF threshold for withdraw / unflag is 1.01e18), borrowers must over-collateralize substantially relative to the displayed LTV. The off-chain matcher must respect this; if frontend displays "borrow at 70% LTV" while on-chain enforces ~41% effective LTV, users will be surprised.

This finding is INFORMATIONAL because the formula is intentional and matches the off-chain `PortfolioService` per the contract NatSpec (`RiskModule.sol:18-27`). It is recorded so that auditors / integrators of future versions notice the divergence from the industry norm.

**Note on a Phase 4 agent claim:** the RiskModule vuln-hunter agent argued this formula makes `canWithdraw` / `canUnflag` impossible for any debt-carrying user. This is **mathematically incorrect** — the agent assumed `hf ≤ weightedLTV`, but in fact `hf = (collateralUsd/debtUsd - 1) * weightedLTV` which grows linearly with collateralization ratio. Withdraw / unflag is achievable at sufficient over-collateralization (table above).

## Recommended Action
Document the divergence prominently in user-facing materials and the operator's matcher logic.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Informational |
| `confidence_0_100` | 100 |
| `gate_failures` | none |
| `poc_status` | N/A |
