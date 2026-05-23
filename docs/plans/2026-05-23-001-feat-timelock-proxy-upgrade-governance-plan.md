---
title: "feat: Add TimeLockController for Proxy Upgrade Governance"
type: feat
status: active
date: 2026-05-23
origin: docs/brainstorms/timelock-integration-requirements.md
deepened: 2026-05-23
---

# feat: Add TimeLockController for Proxy Upgrade Governance

## Overview

Menambahkan **OpenZeppelin `TimelockController`** sebagai pemilik semua `ProxyAdmin` contract di Centuari Protocol. Setiap upgrade logic contract harus melalui mandatory delay **48 jam** (mainnet) / **5 menit** (testnet) sebelum bisa dieksekusi. Perubahan ini **hanya menyentuh lapisan ProxyAdmin** — semua `onlyOwner` function tetap langsung ke multisig tanpa delay tambahan.

---

## Problem Frame

Saat ini seluruh ProxyAdmin dimiliki langsung oleh EOA deployer (testnet) atau multisig (mainnet target). Tidak ada celah waktu antara keputusan upgrade dan eksekusinya — compromise pada kunci multisig akan langsung memungkinkan penggantian logic seluruh contract tanpa ada kesempatan untuk reaksi.

Masalah tambahan: contract yang **sudah live di testnet** perlu dimigrasikan; plan ini hanya men-deploy TimeLock dan pass-nya sebagai `proxyAdminOwner` untuk deployment baru tidak cukup — ProxyAdmin yang sudah ada perlu ditransfer ownershipnya secara eksplisit. (see origin: `docs/brainstorms/timelock-integration-requirements.md`)

---

## Requirements Trace

- R1. Setiap upgrade proxy harus melalui delay minimum 48 jam (mainnet) / 5 menit (testnet).
- R2. Upgrade dapat dibatalkan oleh `CANCELLER_ROLE` selama masa delay berjalan.
- R3. `EXECUTOR_ROLE` hanya dipegang multisig (closed execution — bukan open/address(0)).
- R4. Satu `TimelockController` per chain — hub Arbitrum punya satu, setiap spoke chain punya satu sendiri.
- R5. Semua 8 hub contracts + 3 spoke contracts punya Upgrade script yang dapat dijadwalkan via TimeLock.
- R6. Upgrade scripts tidak mengandung duplikasi logika schedule/execute/cancel.
- R7. `run-all.sh` dan `deploy-spoke.sh` mendeploy TimeLock di awal dan meneruskan `TIMELOCK_ADDRESS` sebagai `proxyAdminOwner`.
- R8. Contract yang sudah live di testnet bisa dimigrasikan ke TimeLock governance tanpa re-deploy.
- R9. `runSchedule` menyimpan operationId + salt ke JSON agar `runExecute` 48 jam kemudian bisa membaca tanpa menebak-nebak.

**Hub contracts yang butuh TimeLock (8):** BalanceLedger, Centuari, Settlement, CollateralManager, HubDepositor, WithdrawalRegistry, HubIntentSettler, SettlementLedger.

**Spoke contracts yang butuh TimeLock (3 per chain):** SpokeVaultStable, SpokePayout, SpokeDepositGateway.

**Tidak butuh TimeLock:** RiskModuleStub (stateless, non-proxy), CentuariBondERC20/Factory (non-proxy), MockTokens, Faucet.

---

## Scope Boundaries

- TimeLock hanya untuk ProxyAdmin (upgrade protection). Owner functions tetap langsung ke multisig.
- Tidak ada DAO governance atau on-chain voting.
- `pause()` tidak di-TimeLock — emergency tetap langsung.
- Satu `DeployTimeLock.s.sol` digunakan ulang untuk hub dan spoke (bukan dua script terpisah).
- Migrasi ownership hanya untuk ProxyAdmin (bukan contract owner).

### Deferred to Follow-Up Work

- Guardian multisig terpisah sebagai second line of defence: future iteration setelah mainnet launch.
- Upgrade delay yang berbeda per contract class: pertimbangkan setelah audit.
- Mengubah `minDelay` setelah TimeLock di-deploy memerlukan operasi self-scheduled via TimeLock sendiri (delay saat ini akan berlaku untuk proses perubahan delay itu sendiri) — dokumentasikan di playbook operasional tapi tidak dalam scope implementasi ini.

---

## Context & Research

### Relevant Code and Patterns

- `lib/openzeppelin-contracts/contracts/governance/TimelockController.sol` — sudah ada di lib.
- Import path: `@openzeppelin/contracts/governance/TimelockController.sol`.
- `TimelockController` constructor OZ v5: `(uint256 minDelay, address[] proposers, address[] executors, address admin)`. Set `admin = address(0)` untuk renounce. **CANCELLER_ROLE otomatis diberikan ke semua `proposers` (bukan executors).**
- `hashOperation(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)` — OZ v5 encode: `keccak256(abi.encode(target, value, data, predecessor, salt))`. Semua 5 parameter harus hadir; `value=0` dan `predecessor=bytes32(0)` harus di-encode eksplisit.
- `script/DeployBalanceLedger.s.sol` — pola `vm.startBroadcast/stopBroadcast`, console.log, return address.
- `script/UpgradeSettlement.s.sol` — pola upgrade saat ini: deploy impl + `ProxyAdmin.upgradeAndCall()` langsung.
- `bin/deploy-spoke.sh` — menggunakan env var `PROXY_ADMIN_OWNER`.
- `bin/run-all.sh` Step 14: memanggil `UpgradeSettlement --sig "run(address,address)"` — harus diupdate setelah `run()` dihapus.

### Institutional Learnings

- Semua deploy script sudah menerima `proxyAdminOwner` sebagai parameter — tidak perlu refaktor signature, hanya nilai yang dipass berubah.
- `_getProxyAdmin()` menggunakan ERC1967 admin slot `0xb53127684...` — konsisten di semua script.
- `TimeLockUpgradeBase` tidak boleh extend `Script` (karena `vm.*` cheatcode tidak tersedia di non-broadcast context), tapi tidak boleh punya `vm.*` call di dalamnya — murni stateless calldata helpers.

### External References

- OZ TimelockController v5 source: `lib/openzeppelin-contracts/contracts/governance/TimelockController.sol`
- ERC1967 admin slot: `0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103`
- Foundry `vm.warp()` — mensimulasikan lewatnya waktu delay di test.

---

## Key Technical Decisions

- **Satu DeployTimeLock.s.sol reusable**: Menerima `minDelay` sebagai parameter — dipakai untuk hub (172800/300) maupun spoke.
- **TimeLockUpgradeBase sebagai abstract contract tanpa `vm.*`**: Hanya calldata helpers murni (no cheatcode, no broadcast). Implementasi broadcast tetap di parent Script.
- **Sebelas Upgrade scripts total (8 hub + 3 spoke)**: Semua mengextend `TimeLockUpgradeBase`. 3 yang ada direfaktor, 8 baru dibuat. Tidak ada duplikasi logika — hanya nama implementation contract yang berbeda.
- **`_computeOperationId` replikasi penuh OZ encoding**: `keccak256(abi.encode(target, 0, data, bytes32(0), salt))` — 5 parameter lengkap agar identik dengan on-chain `hashOperation()`.
- **OperationId + salt disimpan ke JSON**: `runSchedule` menulis file `deployments/scheduled-upgrade-<contractName>-<timestamp>.json` berisi `{operationId, salt, targetImpl, scheduledAt, minDelay, readyAt}`. `runExecute` membaca file ini.
- **Step 14 `run-all.sh` diubah jadi `runSchedule`**: Bukan dihapus. Setelah refaktor, Step 14 memanggil `--sig "runSchedule(...)"` dengan parameter TimeLock. Ini membuat Step 14 menjadi operasi asinkron (schedule dulu, execute manual 48 jam kemudian).
- **`TransferProxyAdminOwnership.s.sol` untuk migrasi testnet**: Script baru yang memanggil `ProxyAdmin.transferOwnership(timeLock)` untuk setiap ProxyAdmin yang sudah ada. Hanya dijalankan sekali per deployment yang sudah live.
- **`EXECUTOR_ROLE` tertutup**: Multisig only. `CANCELLER_ROLE` otomatis ke proposer (multisig) sesuai OZ v5 behavior.

---

## Open Questions

### Resolved During Planning

- **EXECUTOR_ROLE open vs closed?** → Closed (multisig only).
- **Testnet skip TimeLock?** → Tidak di-skip. Delay 300 detik (5 menit).
- **OZ TimelockController tersedia?** → Ya, di `lib/openzeppelin-contracts/contracts/governance/TimelockController.sol`.
- **Apakah deploy scripts perlu diubah internalnya?** → Tidak. Hanya nilai `proxyAdminOwner` yang berubah.
- **CANCELLER_ROLE ke proposer atau executor?** → Proposer saja (sesuai OZ v5 source). Multisig memegang semua tiga role dalam setup ini.
- **Bagaimana runExecute tahu salt yang dipakai saat runSchedule?** → `runSchedule` menulis JSON record; `runExecute` membacanya.
- **Apa yang terjadi dengan contract yang sudah live di testnet?** → `TransferProxyAdminOwnership.s.sol` (U5) dipanggil sekali setelah TimeLock di-deploy.
- **Apakah ada 5 hub contract yang tidak punya upgrade script?** → Ya — BalanceLedger, Centuari, HubDepositor, HubIntentSettler, SettlementLedger. Unit U3 mencakup pembuatan semua upgrade script yang hilang.
- **Apa yang terjadi dengan Step 14 run-all.sh setelah `run()` dihapus?** → Step 14 diupdate memanggil `runSchedule(...)` bukan `run(...)`.

### Deferred to Implementation

- Format salt yang tepat: implementer memilih konvensi (`keccak256(abi.encode(contractName, block.timestamp))` atau lainnya), asalkan unik dan dicatat di JSON output.
- Apakah JSON scheduled-upgrade disimpan di `deployments/` atau di tempat lain.

---

## Output Structure

```
script/
└── timelock/
    ├── DeployTimeLock.s.sol              ← new: deploy TimelockController (hub+spoke reusable)
    ├── TimeLockUpgradeBase.sol           ← new: abstract base (calldata helpers, no vm.*)
    └── TransferProxyAdminOwnership.s.sol ← new: migrate existing ProxyAdmin ke TimeLock

script/
├── UpgradeBalanceLedger.s.sol            ← new
├── UpgradeCentuari.s.sol                 ← new
├── UpgradeHubDepositor.s.sol             ← new
├── UpgradeHubIntentSettler.s.sol         ← new
├── UpgradeSettlementLedger.s.sol         ← new
├── UpgradeSpokeVaultStable.s.sol         ← new
├── UpgradeSpokePayout.s.sol              ← new
├── UpgradeSpokeDepositGateway.s.sol      ← new
├── UpgradeSettlement.s.sol               ← refactor
├── UpgradeCollateralManager.s.sol        ← refactor
└── UpgradeWithdrawalRegistry.s.sol       ← refactor

test/
└── timelock/
    ├── DeployTimeLock.t.sol              ← new: unit test role + delay
    └── TimeLockUpgrade.t.sol             ← new: integration test full lifecycle
```

---

## High-Level Technical Design

> *Ini menggambarkan pendekatan yang dimaksud sebagai panduan arah untuk review, bukan spesifikasi implementasi. Implementing agent harus memperlakukannya sebagai konteks, bukan kode untuk direproduksi.*

### Alur Schedule → Execute

```
Multisig
  │
  ▼ runSchedule(timeLock, proxyAdmin, proxy, salt)
Upgrade<Contract>.s.sol
  │  1. Deploy implementation baru  ← on-chain tx
  │  2. Build calldata: ProxyAdmin.upgradeAndCall(proxy, newImpl, "")
  │  3. Read minDelay dari TimeLock
  │  4. TimeLock.schedule(proxyAdmin, 0, calldata, bytes32(0), salt, minDelay)
  │     → emits CallScheduled(operationId, ...)
  │  5. Tulis JSON: {operationId, salt, newImpl, scheduledAt, readyAt}
  ▼
  [48 jam berlalu / vm.warp di test]
  │
  ▼ runExecute(timeLock, proxyAdmin, proxy, salt) — baca JSON untuk salt + newImpl
Upgrade<Contract>.s.sol
  │  1. Baca scheduled-upgrade JSON (salt, newImpl)
  │  2. Rebuild calldata identik
  │  3. TimeLock.execute(proxyAdmin, 0, calldata, bytes32(0), salt)
  │     → TimeLock calls ProxyAdmin.upgradeAndCall(proxy, newImpl, "")
  │     → Proxy IMPL_SLOT updated → newImpl aktif
  ▼
  ✅ Upgrade selesai. State lama terjaga (storage tidak corrupt).
```

### State Machine TimeLock Operation

```
[Unset]
  │ schedule()
  ▼
[Waiting] ─── cancel() ───► [Cancelled — operationId deleted, Unset kembali]
  │ block.timestamp >= scheduledAt + minDelay
  ▼
[Ready]   ─── cancel() ───► [Cancelled]
  │ execute()
  ▼
[Done]    (terminal — tidak bisa di-cancel)
```

### Hierarki Governance (setelah perubahan)

```
Multisig
  ├── PROPOSER_ROLE + CANCELLER_ROLE + EXECUTOR_ROLE pada TimeLock
  └── owner() pada semua protocol contracts (setOperator, pause, dll — tidak berubah)

TimeLockController (hub — Arbitrum)
  └── ProxyAdmin.owner() untuk 8 hub contracts

TimeLockController (spoke — per chain)
  └── ProxyAdmin.owner() untuk 3 spoke contracts
```

---

## Implementation Units

- U1. **DeployTimeLock Script (Reusable Hub & Spoke)**

**Goal:** Satu Foundry script yang men-deploy `TimelockController` untuk hub maupun spoke chain. Reusable — tidak ada dua script terpisah.

**Requirements:** R1, R3, R4

**Dependencies:** None

**Files:**
- Create: `script/timelock/DeployTimeLock.s.sol`

**Approach:**
- Import `@openzeppelin/contracts/governance/TimelockController.sol`.
- Fungsi `run(uint256 minDelay, address proposer, address executor) external returns (address timelockAddress)`.
- Build `proposers` array `[proposer]` dan `executors` array `[executor]`.
- Set `admin = address(0)` → `DEFAULT_ADMIN_ROLE` hanya dipegang oleh TimeLock sendiri (self-admin).
- `CANCELLER_ROLE` otomatis diberikan ke `proposer` oleh OZ v5 — tidak perlu grant manual.
- Log: timelockAddress, minDelay, proposer, executor, CANCELLER_ROLE note.

**Patterns to follow:**
- `script/DeployBalanceLedger.s.sol` — pola vm.startBroadcast/stopBroadcast, return address, console.log.

**Test scenarios:**
- Happy path: deploy minDelay=172800, proposer=multisig, executor=multisig → `getMinDelay() == 172800`.
- Happy path: `hasRole(PROPOSER_ROLE, multisig) == true`.
- Happy path: `hasRole(EXECUTOR_ROLE, multisig) == true`.
- Happy path: `hasRole(CANCELLER_ROLE, multisig) == true` — diberikan ke proposer oleh OZ v5.
- Happy path: `hasRole(DEFAULT_ADMIN_ROLE, deployer) == false` — admin di-renounce via `admin = address(0)`.
- Happy path: `hasRole(DEFAULT_ADMIN_ROLE, timeLock) == true` — TimeLock self-admin.
- Edge case: deploy minDelay=300 → `getMinDelay() == 300`.
- Edge case: deploy dengan proposer == executor → hanya satu address, tapi kedua role terpenuhi.

**Verification:**
- `forge test --match-path test/timelock/DeployTimeLock.t.sol -vvv` lulus.
- `TimelockController` ter-deploy dengan role dan delay yang benar.

---

- U2. **TimeLockUpgradeBase — Shared Calldata Helpers**

**Goal:** Abstract contract (tanpa `vm.*`, tanpa `Script`) yang memusatkan logika encode calldata, replikasi `hashOperation`, dan helper parameter-building. Semua Upgrade scripts mewarisinya — tidak ada duplikasi.

**Requirements:** R6

**Dependencies:** U1

**Files:**
- Create: `script/timelock/TimeLockUpgradeBase.sol`

**Approach:**
- Abstract contract (bukan `is Script`). Tidak ada state variable. Tidak ada `vm.*` call — murni `internal pure` atau `internal view` helpers.
- `_buildUpgradeCalldata(address proxy, address newImpl, bytes memory initData) internal pure returns (bytes memory)` — encode `ProxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), newImpl, initData)`.
- `_computeOperationId(address target, bytes memory data, bytes32 salt) internal pure returns (bytes32)` — replikasi tepat OZ `hashOperation`: `keccak256(abi.encode(target, uint256(0), data, bytes32(0), salt))`. Semua 5 parameter diisi — `value=0` dan `predecessor=bytes32(0)` di-encode eksplisit agar identik dengan on-chain `hashOperation()`.
- `_buildScheduleArgs(address timeLock, address proxyAdmin, bytes memory upgradeCalldata, bytes32 salt)` → return struct atau tuple: `{target, value, data, predecessor, salt, delay}` yang bisa langsung dipass ke `TimelockController.schedule()`.
- Tidak ada fungsi yang membuat external call langsung — external calls dibuat di parent Script dalam konteks broadcast.

**Patterns to follow:**
- Internal helpers di `script/DeployBalanceLedger.s.sol._getProxyAdmin()`.
- Tidak menggunakan `vm.*` — boundary yang jelas antara helper logic dan Script context.

**Test scenarios:**
- Test expectation: none — `TimeLockUpgradeBase` tidak punya behavior runtime sendiri; diverifikasi melalui U3 dan U6.
- Compile-time: semua Upgrade scripts yang extend `TimeLockUpgradeBase` berhasil `forge build` tanpa error.

**Verification:**
- `forge build` lulus tanpa error.
- `grep -r "ProxyAdmin(proxyAdmin).upgradeAndCall" script/` mengembalikan 0 hasil — tidak ada logika upgrade langsung tersisa di luar `TimeLockUpgradeBase`.

---

- U3. **Buat Semua Upgrade Scripts (8 Hub + 3 Spoke)**

**Goal:** Menyediakan `Upgrade<Contract>.s.sol` untuk semua 11 contract upgradeable. 3 script yang sudah ada direfaktor, 8 script baru dibuat menggunakan pola identik.

**Requirements:** R5, R6

**Dependencies:** U2

**Files:**
- Modify: `script/UpgradeSettlement.s.sol`
- Modify: `script/UpgradeCollateralManager.s.sol`
- Modify: `script/UpgradeWithdrawalRegistry.s.sol`
- Create: `script/UpgradeBalanceLedger.s.sol`
- Create: `script/UpgradeCentuari.s.sol`
- Create: `script/UpgradeHubDepositor.s.sol`
- Create: `script/UpgradeHubIntentSettler.s.sol`
- Create: `script/UpgradeSettlementLedger.s.sol`
- Create: `script/UpgradeSpokeVaultStable.s.sol`
- Create: `script/UpgradeSpokePayout.s.sol`
- Create: `script/UpgradeSpokeDepositGateway.s.sol`

**Approach:**

Setiap script mengikuti pola identik — hanya nama contract implementation yang berbeda:

```
contract Upgrade<X> is Script, TimeLockUpgradeBase {
    function runSchedule(address timeLock, address proxyAdmin, address proxy, bytes32 salt) external {
        // 1. Deploy implementation baru
        // 2. Build calldata via _buildUpgradeCalldata()
        // 3. Read minDelay dari TimeLock
        // 4. vm.startBroadcast(); TimeLock.schedule(...); vm.stopBroadcast();
        // 5. Tulis scheduled-upgrade JSON (operationId, salt, newImpl, scheduledAt, readyAt)
    }

    function runExecute(address timeLock, address proxyAdmin, address proxy, string memory scheduleJsonPath) external {
        // 1. Baca salt + newImpl dari scheduleJsonPath
        // 2. Rebuild calldata identik
        // 3. vm.startBroadcast(); TimeLock.execute(...); vm.stopBroadcast();
        // 4. Tulis execute-upgrade JSON (operationId, executedAt, newImpl)
    }
}
```

- **Hapus** fungsi lama `run()`, `upgrade()`, `upgradeAndCall()`, `upgradeToImplementation()` — tidak lagi bisa digunakan karena ProxyAdmin tidak dimiliki caller langsung.
- **Hapus** import `ProxyAdmin` dan `ITransparentUpgradeableProxy` dari masing-masing script — digantikan oleh logika di `TimeLockUpgradeBase`.
- **Tidak ada duplikasi** — logika calldata building ada di `TimeLockUpgradeBase`. Perbedaan antar script hanya `new <ContractName>()` di baris deploy impl.

**Pola JSON scheduled-upgrade** (ditulis oleh `runSchedule`):
```json
{
  "contractName": "Settlement",
  "operationId": "0x...",
  "salt": "0x...",
  "newImpl": "0x...",
  "proxyAdmin": "0x...",
  "proxy": "0x...",
  "scheduledAt": 1234567890,
  "minDelay": 172800,
  "readyAt": 1234567890
}
```

**Patterns to follow:**
- Pola `runSchedule`/`runExecute` konsisten di semua 11 script.
- `vm.serializeAddress`, `vm.writeJson` (Foundry cheatcodes) untuk menulis JSON output.

**Test scenarios:**
- Happy path: `runSchedule()` emits `CallScheduled` event dari TimeLock dengan operationId yang valid.
- Happy path: JSON scheduled-upgrade ditulis dengan semua field yang diperlukan.
- Happy path: setelah `vm.warp(+minDelay)`, `runExecute()` berhasil → proxy `implementation()` == address(newImpl).
- Happy path: operationId yang dicompute via `_computeOperationId()` identik dengan on-chain `TimeLock.hashOperation()` — verifikasi cross-check.
- Error path: `runExecute()` sebelum delay expired → revert `TimelockUnexpectedOperationState`.
- Error path: non-proposer panggil `TimeLock.schedule()` → revert `AccessControlUnauthorizedAccount`.
- Error path: panggilan langsung `ProxyAdmin.upgradeAndCall()` oleh non-owner (caller bukan TimeLock) → revert `OwnableUnauthorizedAccount`.
- Error path: schedule operasi yang sama dua kali (salt identik) → revert `TimelockUnexpectedOperationState`.
- Edge case: `runSchedule` dengan `initData` non-empty → upgrade + reinitializer dieksekusi di impl baru.
- Integration: storage variable yang di-set sebelum `runSchedule` + `runExecute` masih terjaga setelah upgrade (tidak ada slot collision di `__gap`).
- Security: TimeLock tidak bisa digunakan untuk eksekusi arbitrary call ke contract lain selain ProxyAdmin — verifikasi bahwa `schedule(target=balanceLedger, ...)` reverts jika TimeLock tidak punya role di BalanceLedger (pastikan separation of concern).

**Verification:**
- `forge test --match-path test/timelock/TimeLockUpgrade.t.sol -vvv` lulus.
- `forge build` tanpa error untuk semua 11 script.
- `grep -r "ProxyAdmin(proxyAdmin).upgradeAndCall" script/` mengembalikan 0 hasil.

---

- U4. **TransferProxyAdminOwnership — Migrasi Live Contracts**

**Goal:** Script sekali-pakai untuk memindahkan ownership semua ProxyAdmin yang sudah live di testnet ke TimeLock address. Ini adalah step migrasi — hanya diperlukan untuk deployment yang sudah ada, tidak untuk deployment baru.

**Requirements:** R8

**Dependencies:** U1

**Files:**
- Create: `script/timelock/TransferProxyAdminOwnership.s.sol`

**Approach:**
- Fungsi `run(address timeLock, address[] calldata proxyAdmins) external` — menerima array ProxyAdmin addresses.
- Loop: `ProxyAdmin(proxyAdmins[i]).transferOwnership(timeLock)` untuk setiap address.
- Log sebelum dan sesudah: `ProxyAdmin[i].owner()` sebelum (harus == deployer/multisig) dan sesudah (harus == timeLock).
- Assert setelah transfer: `ProxyAdmin(pa).owner() == timeLock` atau revert.
- Caller script ini harus adalah current `ProxyAdmin.owner()` (deployer atau multisig).
- Untuk testnet: semua 8 hub ProxyAdmin addresses diambil dari `deployments/deploy-arb-sepolia-latest.json`.

**Helper script** (dalam `bin/`): `bin/transfer-proxy-admin-ownership.sh` — membaca ProxyAdmin addresses dari `deployments/deploy-<network>-latest.json` dan memanggil script Foundry.

**Patterns to follow:**
- Pola loop multi-address di `script/ConfigureBalanceLedger.s.sol`.

**Test scenarios:**
- Happy path: setelah `run()`, semua `ProxyAdmin.owner() == timeLock`.
- Error path: caller bukan owner → revert `OwnableUnauthorizedAccount`.
- Error path: `timeLock == address(0)` → revert (tambahkan guard di script).
- Edge case: array kosong → tidak ada perubahan, tidak revert.

**Verification:**
- Setelah `TransferProxyAdminOwnership.run(timeLock, [...8 proxyAdmins...])`, semua 8 `ProxyAdmin.owner()` == `timeLock`.
- `cast call <proxyAdmin> "owner()(address)" --rpc-url $RPC_URL` mengembalikan `TIMELOCK_ADDRESS`.

---

- U5. **Update run-all.sh — Hub TimeLock Integration**

**Goal:** Mendeploy `TimelockController` hub sebagai **Step 0** sebelum semua contract hub, meneruskan `TIMELOCK_ADDRESS` sebagai `proxyAdminOwner` ke setiap deploy step, dan mengupdate Step 14 agar memanggil `runSchedule` (bukan `run` yang sudah dihapus).

**Requirements:** R7

**Dependencies:** U1, U3

**Files:**
- Modify: `bin/run-all.sh`

**Approach:**
- Tambahkan required env var check: `TIMELOCK_PROPOSER` dan `TIMELOCK_EXECUTOR`.
- Tambahkan default: `TIMELOCK_MIN_DELAY="${TIMELOCK_MIN_DELAY:-172800}"`.
- Tambahkan **Step 0** (sebelum Step 1): jalankan `script/timelock/DeployTimeLock.s.sol --sig "run(uint256,address,address)" "$TIMELOCK_MIN_DELAY" "$TIMELOCK_PROPOSER" "$TIMELOCK_EXECUTOR"`.
- Parse `TIMELOCK_ADDRESS` dari output Step 0. Exit 1 jika `TIMELOCK_ADDRESS` kosong.
- Ganti `"$DEPLOYER_ADDRESS"` (sebagai `proxyAdminOwner`) dengan `"$TIMELOCK_ADDRESS"` di Step 3, 4, 7, 9, 11, 16.
- **Step 14**: Ganti `--sig "run(address,address)"` menjadi `--sig "runSchedule(address,address,address,bytes32)"` dengan parameter `TIMELOCK_ADDRESS`, `PROXY_ADMIN`, `PROXY`, `salt`. Tambahkan komentar bahwa ini adalah schedule-only — execute dilakukan manual 48 jam kemudian.
- Tambahkan `timelockAddress`, `timelockMinDelay`, `timelockProposer`, `timelockExecutor` ke `write_deploy_summary()` dan JSON output.
- Tambahkan parser `parse_timelock_address()` — pola sama dengan `parse_balance_ledger_proxy()`.

**Patterns to follow:**
- Pola `parse_balance_ledger_proxy()` untuk parsing output forge script.
- Pola `[[ -z "${BALANCE_LEDGER_ADDRESS:-}" ]]` untuk skip-jika-sudah-ada.

**Test scenarios:**
- Test expectation: none — shell script tidak punya unit test framework. Verifikasi via dry-run `forge script` tanpa `--broadcast`.
- Integration: Step 0 menghasilkan `TIMELOCK_ADDRESS` yang valid (non-empty, 0x...).
- Integration: Step 3 (DeployBalanceLedger) menerima `TIMELOCK_ADDRESS` sebagai proxyAdminOwner.
- Integration: Step 14 memanggil `runSchedule` bukan `run`, tidak revert.
- Integration: deployment JSON mengandung field `timelockAddress`.

**Verification:**
- `./bin/run-all.sh` dry-run (tanpa `--broadcast`) berhasil tanpa error.
- Deployment JSON mengandung `timelockAddress`.
- `ProxyAdmin.owner()` pada semua hub contracts == `TIMELOCK_ADDRESS` setelah deployment.

---

- U6. **Update deploy-spoke.sh — Spoke TimeLock Integration**

**Goal:** Mendeploy `TimelockController` spoke sebelum spoke contracts, menggunakan `SPOKE_TIMELOCK_ADDRESS` sebagai `PROXY_ADMIN_OWNER`.

**Requirements:** R4, R7

**Dependencies:** U1

**Files:**
- Modify: `bin/deploy-spoke.sh`

**Approach:**
- Tambahkan required env vars: `TIMELOCK_PROPOSER`, `TIMELOCK_EXECUTOR`, `TIMELOCK_MIN_DELAY` (default 172800).
- Hapus required env var `PROXY_ADMIN_OWNER` — digantikan oleh TimeLock.
- Tambahkan langkah awal: jalankan `DeployTimeLock.s.sol` dengan `--rpc-url $SPOKE_RPC_URL` untuk mendeploy spoke TimeLock.
- Parse `SPOKE_TIMELOCK_ADDRESS` dari output.
- Pass `SPOKE_TIMELOCK_ADDRESS` sebagai `$4` (posisi `proxyAdminOwner`) ke `DeploySpokeContracts.s.sol`.
- Tambahkan `spokeTimelockAddress`, `timelockMinDelay`, `timelockProposer` ke `deploy-spoke-${CHAIN_ID}-latest.json`.

**Patterns to follow:**
- Pola `parse_addr()` yang sudah ada di `deploy-spoke.sh`.

**Test scenarios:**
- Test expectation: none — verifikasi manual.
- Integration: `deploy-spoke-${CHAIN_ID}-latest.json` mengandung `spokeTimelockAddress`.
- Integration: semua spoke ProxyAdmin `owner() == SPOKE_TIMELOCK_ADDRESS`.

**Verification:**
- `deploy-spoke.sh` berhasil tanpa error.
- JSON deployment spoke memiliki field `spokeTimelockAddress`.
- `ProxyAdmin.owner()` pada SpokeVaultStable, SpokePayout, SpokeDepositGateway == `SPOKE_TIMELOCK_ADDRESS`.

---

- U7. **Unit & Integration Tests**

**Goal:** Membuktikan bahwa seluruh TimeLock flow — deploy, schedule upgrade, cancel, execute setelah delay, storage preservation, dan keamanan arbitrary-call prevention — bekerja benar via Foundry tests.

**Requirements:** R1, R2, R3, R4, R5, R6 (semua)

**Dependencies:** U1, U2, U3

**Files:**
- Create: `test/timelock/DeployTimeLock.t.sol`
- Create: `test/timelock/TimeLockUpgrade.t.sol`

**Approach:**

*`DeployTimeLock.t.sol` (unit test):*
- Deploy `TimelockController` langsung dengan parameter identik seperti di `DeployTimeLock.s.sol`.
- Assert semua role assignments dan minDelay.

*`TimeLockUpgrade.t.sol` (integration test):*
- Setup: deploy Settlement + TransparentUpgradeableProxy dengan `proxyAdminOwner = address(timeLock)`.
- Deploy TimeLock dengan `proposer = address(this)`, `executor = address(this)`, `minDelay = 300`.
- Semua test dibungkus dengan `vm.prank(address(this))` untuk simulasi multisig.
- Gunakan `vm.warp()` untuk simulasi waktu.

**Patterns to follow:**
- `test/settlement/Settlement.t.sol` — pola deploy Settlement via TransparentUpgradeableProxy, mock dependencies.
- `vm.prank()`, `vm.warp()`, `vm.expectRevert()`.
- Baca IMPL_SLOT langsung: `vm.load(proxy, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)`.

**Test scenarios:**

*Unit (DeployTimeLock.t.sol):*
- Happy path: `getMinDelay() == 172800` setelah deploy dengan minDelay=172800.
- Happy path: `hasRole(PROPOSER_ROLE, multisig) == true`.
- Happy path: `hasRole(EXECUTOR_ROLE, multisig) == true`.
- Happy path: `hasRole(CANCELLER_ROLE, multisig) == true`.
- Happy path: `hasRole(DEFAULT_ADMIN_ROLE, deployer) == false`.
- Happy path: `hasRole(DEFAULT_ADMIN_ROLE, timeLock) == true`.
- Edge case: minDelay=300 → `getMinDelay() == 300`.

*Integration (TimeLockUpgrade.t.sol):*
- Happy path: `ProxyAdmin.owner() == address(timeLock)` setelah setup.
- Error path: non-TimeLock address panggil `ProxyAdmin.upgradeAndCall()` → revert `OwnableUnauthorizedAccount`.
- Error path: non-proposer panggil `TimeLock.schedule(...)` → revert `AccessControlUnauthorizedAccount`.
- Error path: non-executor panggil `TimeLock.execute(...)` → revert `AccessControlUnauthorizedAccount`.
- Error path: `TimeLock.execute(...)` sebelum delay expired → revert `TimelockUnexpectedOperationState`.
- Happy path: setelah `vm.warp(block.timestamp + 300)`, `TimeLock.execute(...)` berhasil.
- Happy path: setelah execute, `vm.load(proxy, IMPL_SLOT) == address(newImpl)`.
- Happy path: state variable Settlement (e.g., `_operator`) yang di-set sebelum upgrade masih terjaga setelah upgrade — verifikasi storage preservation.
- Happy path: cancel flow — `TimeLock.schedule()` → `vm.prank(multisig) → TimeLock.cancel(operationId)` → setelah warp, `TimeLock.execute()` revert `TimelockUnexpectedOperationState`.
- Edge case: schedule operasi yang sama dua kali (salt identik) → revert `TimelockUnexpectedOperationState`.
- Edge case: upgrade dengan `initData` non-empty (verifikasi reinitializer dipanggil di impl baru).
- Security: `_computeOperationId(target, data, salt)` dalam `TimeLockUpgradeBase` menghasilkan hash identik dengan on-chain `TimeLock.hashOperation(target, 0, data, bytes32(0), salt)` — cross-check eksplisit.
- Security: TimeLock tidak bisa digunakan untuk eksekusi arbitrary call ke BalanceLedger — `TimeLock.schedule(target=balanceLedger, data=credit(...), ...)` lalu execute → revert karena TimeLock tidak punya `AUTHORIZED_WRITER` role di BalanceLedger.

**Verification:**
- `forge test --match-path "test/timelock/*" -vvv` lulus semua tanpa revert.
- Coverage mencakup semua 4 state machine state: Unset, Waiting, Ready, Done.
- Storage preservation test membuktikan tidak ada slot collision.
- Security test membuktikan arbitrary call prevention.

---

## System-Wide Impact

- **Interaction graph:** Tidak ada perubahan pada alur settlement, repay, deposit, atau withdrawal. `ProxyAdmin` menjadi intermediary yang dikontrol oleh TimeLock, bukan EOA/multisig langsung.
- **Error propagation:** Jika Step 0 (DeployTimeLock) gagal di `run-all.sh`, semua deploy step berikutnya akan exit 1 karena `TIMELOCK_ADDRESS` kosong. Error ini intentional dan tepat.
- **State lifecycle risks:** Jika upgrade dijadwalkan tapi tidak di-execute, state ProxyAdmin tidak berubah. Tidak ada risiko partial-write. OperationState tetap `Ready` tanpa expiry — upgrade tetap bisa di-execute kapanpun setelah delay.
- **API surface parity:** Step 14 `run-all.sh` berubah dari sinkron (`run()`) menjadi asinkron (`runSchedule()`). Tim harus memperbarui playbook operasional.
- **Integration coverage:** Test `TimeLockUpgrade.t.sol` membuktikan full lifecycle pada fork lokal — termasuk storage preservation dan arbitrary call prevention yang tidak bisa dibuktikan hanya dengan unit test.
- **Unchanged invariants:** Semua contract logic, ABI, storage layout, dan `onlyOwner` function paths tidak berubah. Hanya ownership ProxyAdmin yang berpindah ke TimeLock.
- **minDelay change:** Mengubah `minDelay` setelah TimeLock di-deploy memerlukan operasi self-scheduled via TimeLock itu sendiri (48 jam delay). Ini adalah fitur keamanan, bukan bug — dokumentasikan di playbook operasional.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Salt collision — dua schedule dengan salt identik → revert | Gunakan konvensi salt: `keccak256(abi.encode(contractName, block.timestamp))`; log salt di JSON |
| runExecute membawa salt yang berbeda dengan runSchedule → execute gagal | JSON scheduled-upgrade record adalah sumber kebenaran; `runExecute` wajib baca dari sana |
| 5 contract tidak punya upgrade script sebelum PR ini (F1 dari review) | U3 mencakup pembuatan semua 11 Upgrade scripts |
| Contract yang sudah live di testnet tidak ter-cover (F3 dari review) | U4 `TransferProxyAdminOwnership.s.sol` menangani migrasi |
| Step 14 `run-all.sh` memanggil `run()` yang sudah dihapus (F6 dari review) | U5 mengupdate Step 14 ke `runSchedule()` |
| `_computeOperationId` encoding diverge dari OZ (F2 dari review) | U2 mewajibkan 5-parameter encoding dengan value=0 dan predecessor=bytes32(0); U7 test cross-check eksplisit |
| Multisig lupa execute setelah delay — upgrade terjadwal tapi tidak pernah dieksekusi | OperationState tetap Ready; tambahkan monitoring alert off-chain (di luar scope ini) |
| TimeLock digunakan untuk arbitrary call (mis. credit BalanceLedger) | U7 security test membuktikan ini tidak bisa terjadi |

---

## Documentation / Operational Notes

- Perbarui docs operasional dengan playbook upgrade baru: `runSchedule → tunggu delay → runExecute`.
- `deployments/deploy-<network>-latest.json` wajib mengandung `timelockAddress`.
- `deployments/scheduled-upgrade-<contractName>-<timestamp>.json` adalah sumber kebenaran untuk `runExecute`.
- Testnet: `TIMELOCK_MIN_DELAY=300`; mainnet: `TIMELOCK_MIN_DELAY=172800`.
- **Mengubah `minDelay`**: TimeLock bersifat self-admin. Untuk ubah `minDelay`, harus schedule operasi `TimeLock.updateDelay(newDelay)` via `TimeLock.schedule(timeLock, 0, updateDelayCalldata, ...)` — delay yang berlaku adalah `minDelay` saat ini.
- Jika critical bug ditemukan saat upgrade sudah dijadwalkan: cancel dulu, deploy hotfix ke impl baru, jadwalkan ulang.
- Setelah migrasi testnet via U4: jalankan `cast call <proxyAdmin> "owner()(address)"` untuk verifikasi setiap ProxyAdmin sudah pindah ke TimeLock.

---

## Sources & References

- **Origin document:** [docs/brainstorms/timelock-integration-requirements.md](docs/brainstorms/timelock-integration-requirements.md)
- Related code: `script/UpgradeSettlement.s.sol`, `script/DeployBalanceLedger.s.sol`, `bin/run-all.sh`
- OZ TimelockController v5: `lib/openzeppelin-contracts/contracts/governance/TimelockController.sol`
- ERC1967 implementation slot: `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`
- ERC1967 admin slot: `0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103`
