# Phase 4 Plan - Parallel Vuln-Hunter Subsystem Split

audit_date: 2026-06-05

## Subsystem map (in-scope only)

| Agent | Subsystem | Files (LoC) | Brief |
|-------|-----------|-------------|-------|
| A1 | BalanceLedger | BalanceLedger.sol (308), BalanceLedgerStorage.sol (133) | Writer mgmt, credit/debit, flag invariants, pause, idempotency |
| A2 | Centuari core flow | Centuari.sol (614), CentuariStorage.sol (114) | settleMatch, repay, liquidationRepay, withdrawLendPosition, day-count math, MAX_DEBT_MARKETS, seedBorrowerMarkets |
| A3 | Bond token + Factory | CentuariBondERC20.sol (94), CentuariBondERC20Factory.sol (209), DateTime.sol (97) | Mint/burn auth, CREATE2 determinism, custody invariant |
| A4 | Settlement | Settlement.sol (248), SettlementStorage.sol (41) | matchId dedup, validation, CEI, batch atomicity |
| A5 | CollateralManager | CollateralManager.sol (213), CollateralManagerStorage.sol (49) | flag lock, canUnflag gate, operator vs direct paths, MAX_FLAG_LOCK |
| A6 | LiquidationEngine | LiquidationEngine.sol (300), LiquidationEngineStorage.sol (55) | matured/HF trigger, close factor, USD↔base math, _usdToBaseUnits inverse, capping, slippage, auto-unflag |
| A7 | RiskModule | RiskModule.sol (259), RiskModuleStorage.sol (40) | HF formula, weightedLTV, buffer threshold, fail-closed, debt-first ordering |
| A8 | Oracle stack | OracleRouter.sol (106), ChainlinkPriceFeed.sol (76), PushOracle.sol (139) | Staleness, sequencer feed, deviation guard, min/maxAnswer, decimals |

## Cross-cutting attack vectors (auditor pre-loaded with these)

- `lending.md`: liquidation math, close factor, bad debt, donation attacks (where applicable)
- `oracle-integration.md`: staleness, sequencer, min/max bounds, decimals, fail-closed
- Plus Centuari-specific framings (see INVARIANTS.md "Adversarial framings"):
  - Operator-controlled `marketId` divergence from canonical hash
  - Day-count interest off-by-one
  - Multi-update deviation defeat
  - LTV=0 collateral interaction
  - Auto-unflag race
  - Borrower self-liquidation as repay escape hatch
  - Multi-collateral HF formula edge cases
  - Operator submitting fake settlements

## Out of scope (do NOT analyze)

- src/core/cross-chain/ (HubDepositor, HubIntentSettler, SettlementLedger, WithdrawalRegistry, spoke/*)
- src/interfaces/cross-chain/
- src/mocks/
- lib/

Boundary exploration allowed: any in-scope contract that trusts a cross-chain
contract for writing (e.g., BalanceLedger writer set includes WithdrawalRegistry)
is fair game for trust-boundary analysis, but findings must target in-scope code.

## Agent dispatch order

All 8 agents spawn in parallel. Each receives:
- File paths + LoC
- ARCHITECTURE.md + INVARIANTS.md
- Slither output (slither-high-impact.txt)
- Known-design-by-intent items to skip (operator trust, repay-via-operator, hub-aware solvency)
- Explicit "no PoC required from agent" — exploit-writer is Phase 7

Each agent should report: candidate findings with file:line, severity hypothesis,
attacker path, smallest falsifier.
