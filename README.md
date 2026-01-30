## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Running all scripts

To run all deployment scripts in order (DeployMockTokens → DeployFaucet → DeploySettlement → UpgradeSettlement when env is set):

```shell
$ ./script/run-all.sh [FORGE_SCRIPT_FLAGS...]
```

Example with broadcast:

```shell
$ RPC_URL=https://... PRIVATE_KEY=0x... ./script/run-all.sh --broadcast
```

Use `--deploy-only` to skip UpgradeSettlement. DeploySettlement runs only when `SETTLEMENT_OWNER`, `SETTLEMENT_OPERATOR`, `CENTUARI_ADDRESS`, and `PROXY_ADMIN_OWNER` are set; UpgradeSettlement runs only when `PROXY_ADMIN` and `SETTLEMENT_PROXY` (or `PROXY`) are set. See the env var table in `script/run-all.sh` for full documentation.

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
