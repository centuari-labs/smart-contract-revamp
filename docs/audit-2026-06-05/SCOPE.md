# Scope

audit_date: 2026-06-05
source_commit: 8a9451194e27df4abaced439d1c49e119a9b2456
scope_sha256: (computed at audit close)

## Protocol overview

Centuari is a fixed-rate, fixed-maturity lending and borrowing protocol on
Arbitrum Sepolia. Lenders deposit a loan token until a chosen maturity; borrowers
post collateral and are matched against lender orders by an off-chain matcher
that the protocol settles in batches on-chain. Cross-chain spoke/hub flow exists
but is OUT OF SCOPE for this audit.

## In-scope contracts (hub core, EVM Solidity 0.8.x, upgradeable behind
ERC1967 Transparent Proxy except libraries)

| Contract | LoC | Role |
|----------|-----|------|
| BalanceLedger.sol | 308 | 3-state balance accounting + on-chain collateral flag, writer-gated |
| BalanceLedgerStorage.sol | 133 | Storage layout for BalanceLedger |
| Centuari.sol | 614 | Lending + borrowing core, settles matches, accrues interest |
| CentuariStorage.sol | 114 | Storage for Centuari |
| CentuariBondERC20.sol | 94 | ERC20 bond token, mint/burn by Centuari |
| CentuariBondERC20Factory.sol | 209 | Deploys CentuariBondERC20 per market |
| CollateralManager.sol | 213 | Manages collateral flag with 24h lock, gates unflag via RiskModule |
| CollateralManagerStorage.sol | n/a | Storage for CollateralManager |
| LiquidationEngine.sol | 300 | Closeout flow for unhealthy / matured borrowers |
| LiquidationEngineStorage.sol | 55 | Storage for LiquidationEngine |
| RiskModule.sol | 259 | Oracle-backed health-factor policy |
| RiskModuleStorage.sol | n/a | Storage for RiskModule |
| Settlement.sol | 248 | Batch settlement processor |
| SettlementStorage.sol | n/a | Storage for Settlement |
| OracleRouter.sol | 106 | Aggregates underlying oracle adapters |
| OracleRouterStorage.sol | n/a | Storage for OracleRouter |
| ChainlinkPriceFeed.sol | 76 | Chainlink AggregatorV3 adapter |
| PushOracle.sol | 139 | Operator-pushed price adapter |
| DateTime.sol | 97 | Date formatting library for bond token names |
| ReentrancyGuardUpgradeable.sol | 106 | ERC7201 namespaced reentrancy guard |

Total source under audit: ~3300 LoC (excluding cross-chain).

## Out-of-scope contracts

- All cross-chain hub (HubDepositor, WithdrawalRegistry, HubIntentSettler,
  SettlementLedger) and spoke contracts.
- Mock contracts (MockToken, Faucet).

## Severity matrix (inferred; protocol is pre-mainnet so use industry norm)

Bounty platform: NONE - this is an internal audit. We use the standard auditor
severity matrix:

- **Critical**: direct loss of >5% protocol funds, attacker net-profitable, low cost.
- **High**: loss of funds requiring conditional access (matured / expired / specific
  market), or permanent freeze of >1% funds, or attacker grief at no cost to themselves.
- **Medium**: temporary loss, recoverable funds, conditional griefing, accounting drift
  detectable but bounded.
- **Low**: theoretical / requires upgrade-only fix / privileged-only.
- **Informational**: best-practice / no exploit path.

## Known prior fixes (from git log on this branch)

- M2 fix at commit 18a9a64: MAX_DEBT_MARKETS cap in seedBorrowerMarkets.
- WithdrawalRegistry fix at c84b16c: restore chain liquidity on failed SPOKE_NATIVE withdrawal (cross-chain, OOS).
- Timelock governance tooling at 1911e74.

These will be cross-referenced. Any remaining attack on the M2 fix path is in
scope; the cross-chain withdrawal fix is OOS.
