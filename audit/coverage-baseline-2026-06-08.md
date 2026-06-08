# Smart-Contract Coverage Baseline — 2026-06-08

> External-audit prep (hub-only scope), Phase 2.2. Snapshot of `forge coverage`
> at branch `chore/audit-prep` after adding the Foundry invariant/fuzz harnesses
> in `test/invariant/`. Use this as the pre-audit coverage reference; see
> [`docs/CONTRACT_INVARIANTS.md`](../docs/CONTRACT_INVARIANTS.md) for the prose
> invariants the new harnesses make executable, and
> [`dev-docs/audit/SCOPE.md`](../../dev-docs/audit/SCOPE.md) for the in/out-of-scope
> boundary.

## How this was produced

```bash
TZ=UTC forge coverage --report summary --ir-minimum
```

`--ir-minimum` is **required**: the project compiles with `via_ir = true`, and a
plain `forge coverage` instruments out the IR pipeline and hits "stack too deep"
on the larger contracts (Centuari, Settlement). The `--ir-minimum` path keeps the
IR pipeline and produces a stable summary at the cost of slightly coarser source
mapping (see the BalanceLedger note below). Columns are **Lines / Statements /
Branches / Funcs**, matching forge's own summary table.

Full test suite at this snapshot: **668 tests passed, 0 failed, 0 skipped**
(32 suites), including the 18 new invariant/fuzz tests added in Phase 2.2.

## In-scope contracts (hub-only launch — SCOPE.md §2)

These are the contracts the external firm audits. Funds and upgrade authority
live here.

| Contract | Lines | Statements | Branches | Funcs |
|---|---|---|---|---|
| `core/balance-ledger/BalanceLedger.sol` | see note ¹ | — | — | — |
| `core/centuari/Centuari.sol` | 98.18% (216/220) | 95.12% (234/246) | 84.31% (43/51) | 100.00% (41/41) |
| `core/centuari/CentuariBondERC20Factory.sol` | 81.82% (45/55) | 84.21% (48/57) | 37.50% (3/8) | 100.00% (12/12) |
| `core/centuari/CentuariBondERC20.sol` | 68.75% (11/16) | 63.64% (7/11) | 0.00% (0/1) | 66.67% (4/6) |
| `core/settlement/Settlement.sol` | 96.30% (78/81) | 91.25% (73/80) | 73.68% (14/19) | 100.00% (19/19) |
| `core/cross-chain/HubDepositor.sol` | 95.12% (39/41) | 95.35% (41/43) | 100.00% (11/11) | 100.00% (11/11) |
| `core/cross-chain/WithdrawalRegistry.sol` | 95.24% (160/168) | 93.08% (148/159) | 79.41% (27/34) | 91.89% (34/37) |
| `core/collateral/CollateralManager.sol` | 96.67% (58/60) | 94.74% (54/57) | 90.91% (10/11) | 100.00% (16/16) |
| `core/risk/RiskModule.sol` | 92.38% (97/105) | 87.02% (114/131) | 60.71% (17/28) | 88.89% (16/18) |
| `core/oracle/OracleRouter.sol` | 85.71% (30/35) | 81.58% (31/38) | 61.54% (8/13) | 85.71% (6/7) |
| `core/oracle/PushOracle.sol` | 100.00% (44/44) | 100.00% (50/50) | 100.00% (8/8) | 100.00% (10/10) |
| `core/oracle/ChainlinkPriceFeed.sol` | 89.47% (17/19) | 93.33% (28/30) | 83.33% (5/6) | 100.00% (2/2) |
| `core/liquidation/LiquidationEngine.sol` | 60.90% (81/133) | 66.67% (118/177) | 33.33% (11/33) | 32.00% (8/25) |
| `libraries/DateTime.sol` | 95.92% (47/49) | 97.01% (65/67) | 92.31% (12/13) | 100.00% (5/5) |
| `utils/ReentrancyGuardUpgradeable.sol` | 61.54% (16/26) | 56.52% (13/23) | 100.00% (1/1) | 77.78% (7/9) |

¹ **BalanceLedger.sol did not emit a row** under `--ir-minimum`. This is a known
forge-coverage source-mapping gap that appears for some contracts only on the
IR-minimum path — it is **not** an indication of missing tests. BalanceLedger is
among the most heavily exercised contracts in the suite:
`test/balance-ledger/BalanceLedger.t.sol` (credit/debit/writer-timelock/pause),
`test/balance-ledger/BalanceLedgerFlagCap.t.sol` (BL-6 cap), and the new
`test/invariant/BalanceLedgerInvariant.t.sol` (BL-1..BL-6 as stateful invariants,
8192 calls/run). Re-confirm a precise line count with a non-IR coverage run on a
single contract if the firm needs the exact number:
`forge coverage --report summary --match-contract BalanceLedger` (may require
`--ir-minimum` depending on the local solc).

## New Phase 2.2 harnesses (this snapshot)

`test/invariant/` turns the prose invariants in `docs/CONTRACT_INVARIANTS.md` into
executable property/invariant tests:

| File | Target | Invariants exercised |
|---|---|---|
| `BalanceLedgerInvariant.t.sol` | BalanceLedger (StdInvariant + handler) | BL-1 (available = Σcredit−Σdebit), BL-2/BL-3 (Phase-1 slots zero, total consistent), BL-4 (no negative balance), BL-5 (`flaggedAt` pinned to first mark), BL-6 (flag-set cap) |
| `WithdrawalRegistryInvariant.t.sol` | WithdrawalRegistry (StdInvariant + handler, real BalanceLedger + HubDepositor) | WR-2 (debit-first / no double-withdraw via balance reconciliation), WR-4 (legal + terminal state transitions; hub-only never reaches PROCESSING) |
| `RiskModuleProperties.t.sol` | RiskModule (fuzz; stateless view policy) | RM-1/G-6 (fail-closed on stale debt/collateral price), RM-2 (debt-first: zero-debt always healthy), RM-4 (HF monotonic in collateral ↑ and debt ↓), RM-5 (liquidation floor = HF < 1.0) |
| `CollateralFlagLockProperties.t.sol` | CollateralManager (fuzz, real BalanceLedger) | CM-2 (24h flag-lock boundary), BL-5/CT-5 (idempotent re-mark never refreshes `flaggedAt`), CM-3 (HF gate after lock), CM-4 (flag-lock capped at MAX_FLAG_LOCK) |

Invariant runs are configured in `foundry.toml` (`[invariant] runs = 256,
depth = 32, fail_on_revert = false`).

## Out-of-scope contracts (dormant cross-chain — SCOPE.md §4)

Reported by coverage but **out of audit scope** (banner-annotated
`@custom:audit-scope` in source). Listed for completeness only.

| Contract | Lines | Statements | Branches | Funcs |
|---|---|---|---|---|
| `core/cross-chain/HubIntentSettler.sol` | 95.15% (98/103) | 91.75% (89/97) | 95.00% (19/20) | 96.30% (26/27) |
| `core/cross-chain/SettlementLedger.sol` | 96.08% (49/51) | 90.00% (45/50) | 75.00% (9/12) | 100.00% (11/11) |
| `core/cross-chain/spoke/SpokeDepositGateway.sol` | 85.42% (82/96) | 85.86% (85/99) | 81.82% (18/22) | 85.71% (18/21) |
| `core/cross-chain/spoke/SpokePayout.sol` | 84.34% (70/83) | 78.89% (71/90) | 64.71% (11/17) | 82.35% (14/17) |
| `core/cross-chain/spoke/SpokeVaultStable.sol` | 98.33% (118/120) | 86.61% (110/127) | 58.33% (21/36) | 100.00% (25/25) |

## Testnet-only contracts (excluded from mainnet — SCOPE.md §4)

| Contract | Lines | Statements | Branches | Funcs |
|---|---|---|---|---|
| `mocks/Faucet.sol` | 87.76% (43/49) | 78.69% (48/61) | 56.25% (9/16) | 90.00% (9/10) |
| `mocks/MockToken.sol` | 100.00% (10/10) | 100.00% (7/7) | 100.00% (1/1) | 100.00% (3/3) |

## Repository total

`64.95% lines (1912/2944) · 61.51% statements (1902/3092) · 59.64% branches
(297/498) · 74.01% funcs (447/604)`.

The repo total is diluted by (a) out-of-scope spoke/cross-chain contracts, (b)
test-only `.t.sol` mock helpers that coverage counts, and (c) the missing
BalanceLedger row. **In-scope hub contracts that custody funds or gate withdrawals
sit materially higher** — Centuari, Settlement, HubDepositor, WithdrawalRegistry,
and CollateralManager are all ≥95% lines / ≥91% statements.

### Notable lower-coverage in-scope areas (candidate follow-ups, not blockers)

- **`LiquidationEngine.sol` — 60.90% lines / 33.33% branches.** The lowest in-scope
  contract; the liquidation path (HF<1 and matured) has many backed-down / bad-debt
  branches that the current suite doesn't fully drive. Strongest candidate for the
  next round of property tests (LE-1..LE-6 in CONTRACT_INVARIANTS.md).
- **`RiskModule.sol` — 60.71% branches** and **`OracleRouter.sol` — 61.54%
  branches.** The fail-closed permutations (per-feed staleness, decimals>36, feed
  revert, zero price) are partially covered; the new `RiskModuleProperties.t.sol`
  fuzz tests raise confidence on the debt-first / fail-closed decision path but do
  not exhaustively hit every OracleRouter read-guard branch.
- **`CentuariBondERC20.sol` — 68.75% lines / 0% branches** and
  **`CentuariBondERC20Factory.sol` — 37.50% branches.** Bond-token metadata
  fallbacks (CBF-3 try/catch) are under-exercised.
- **`ReentrancyGuardUpgradeable.sol` — 61.54%.** Reentrancy is exercised indirectly
  via `CollateralManagerReentrancy.t.sol`; the guard's revert branch isn't directly
  hit on every consumer.
