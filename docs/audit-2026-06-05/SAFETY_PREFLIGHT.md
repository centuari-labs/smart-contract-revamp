# Safety Preflight

audit_date: 2026-06-05
source_commit: 8a9451194e27df4abaced439d1c49e119a9b2456
branch: staging
auditor: Claude Opus 4.7 (web3-pentest skill)
target_repo: /Users/singgihbriliantara/Documents copy/centuari/centuari-smart-contract-v2/smart-contract-revamp

## In-scope contracts (per user instruction, "all scope except cross-chain")

Hub-side core contracts only:

- src/core/balance-ledger/BalanceLedger.sol + BalanceLedgerStorage.sol
- src/core/centuari/Centuari.sol + CentuariStorage.sol
- src/core/centuari/CentuariBondERC20.sol
- src/core/centuari/CentuariBondERC20Factory.sol
- src/core/collateral/CollateralManager.sol + CollateralManagerStorage.sol
- src/core/liquidation/LiquidationEngine.sol + LiquidationEngineStorage.sol
- src/core/oracle/OracleRouter.sol + OracleRouterStorage.sol
- src/core/oracle/ChainlinkPriceFeed.sol
- src/core/oracle/PushOracle.sol
- src/core/risk/RiskModule.sol + RiskModuleStorage.sol
- src/core/settlement/Settlement.sol + SettlementStorage.sol
- src/libraries/DateTime.sol
- src/utils/ReentrancyGuardUpgradeable.sol

Supporting interfaces in `src/interfaces/` (read for context, not audited as source).

## Out-of-scope (per user instruction)

- src/core/cross-chain/ (HubDepositor, HubIntentSettler, SettlementLedger, WithdrawalRegistry, spoke/*)
- src/interfaces/cross-chain/ (interfaces only)
- src/mocks/ (testnet only)

Boundary exploration is allowed: any in-scope contract that trusts a cross-chain
contract (e.g. BalanceLedger writer set, WithdrawalRegistry as caller) is fair game
for trust-boundary analysis, but findings ship only against in-scope contracts.

## Allowed actions

- Read source, run forge build / forge test / forge inspect locally.
- Run slither, aderyn (if available), halmos (if applicable).
- Spawn vuln-hunter sub-agents on isolated subsystems.
- Write Foundry tests to `test/exploits/centuari-2026-06-05/` for PoC validation.
- All exploit tests run on local foundry test or anvil; never on a live RPC.

## Forbidden actions

- No `cast send`, `forge script --broadcast`, or `forge create` against any real chain.
- No interaction with deployed Arbitrum Sepolia / Arbitrum One contracts; this is
  a pure source-code + local-fuzz audit.
- No data exfiltration beyond what the user already shared.
- No editing of contract source. PoCs and audit artefacts only.

## Output directory

All artefacts written to `docs/audit-2026-06-05/`. PoCs (if any) go to
`test/exploits/centuari-2026-06-05/`.

## Adversarial stance

I will act as a senior auditor + rational profit-maximising attacker. Every
modifier, every external call, every math operation is a claim to falsify.
"By design" is not accepted without a code-or-math citation.
