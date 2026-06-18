# Deferred — cross-chain / spoke Foundry scripts

These scripts belong to the **deferred cross-chain phase** and are **not used by the
hub-only launch** on Arbitrum Sepolia. They are kept here (and kept compiling) so they're
ready when cross-chain work resumes.

Contents:
- `DeploySpokeContracts.s.sol` — deploy SpokeVaultStable + SpokePayout + SpokeDepositGateway to a spoke chain
- `ConfigureSpokeForM5.s.sol` / `ConfigureHubForM5.s.sol` — LayerZero wiring (spoke side / hub side)
- `BurnInSpokeDeposit.s.sol` — M8 end-to-end spoke-deposit burn-in
- `UpgradeSpokeVaultStable.s.sol` / `UpgradeSpokePayout.s.sol` / `UpgradeSpokeDepositGateway.s.sol` — TimelockController upgrades for the spoke contracts (inherit `../timelock/UpgradeScriptBase.sol`)

Driven by `bin/deferred/run-all-cross-chain.sh` and `bin/deferred/deploy-spoke.sh`.
Imports reach the sources via `../../src/...` (one level deeper than the hub scripts in `script/`).

See `dev-docs/architecture-html/launches/cross-chain.html` for the cross-chain plan.
