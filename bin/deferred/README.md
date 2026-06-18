# Deferred — cross-chain / spoke orchestration

Shell scripts for the **deferred cross-chain phase** — **not used by the hub-only launch**.
Kept here, with paths pointing back at the repo root, ready for when cross-chain resumes.

Contents:
- `run-all-cross-chain.sh` — 6-phase hub + 4-spoke orchestrator. Calls the hub deployer at
  `../run-all.sh`, sources `lz-testnet-config.sh`, and invokes `deploy-spoke.sh` per spoke.
- `deploy-spoke.sh` — deploy the three spoke contracts to one chain
  (`script/deferred/DeploySpokeContracts.s.sol`).
- `lz-testnet-config.sh` — sourceable LayerZero V2 testnet endpoints + EIDs.

These scripts `cd` to the repo root (two levels up from here) before running, so forge-script
paths are repo-relative (`script/deferred/...`).

See `dev-docs/architecture-html/launches/cross-chain.html` for the cross-chain plan.
