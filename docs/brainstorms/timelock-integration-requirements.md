# TimeLockController Integration — Requirements Document

**Status:** Draft  
**Created:** 2026-05-23  
**Author:** Centuari Team  
**Scope:** Governance hardening — proxy upgrade protection via OpenZeppelin TimelockController  

---

## 1. Overview

Centuari menggunakan pola ERC1967 Transparent Proxy untuk semua contract upgradeable. Saat ini, `ProxyAdmin` dimiliki langsung oleh EOA deployer (testnet) atau multisig (mainnet target). Tidak ada delay antara "keputusan untuk upgrade" dan "eksekusi upgrade".

Fitur ini menambahkan **OpenZeppelin `TimelockController`** sebagai pemilik semua `ProxyAdmin`, sehingga setiap upgrade contract harus melalui mandatory delay **48 jam** sebelum bisa dieksekusi. Ini memberi waktu bagi tim, auditor, dan komunitas untuk mendeteksi dan membatalkan upgrade berbahaya.

---

## 2. Goals

- Setiap upgrade proxy (perubahan logic contract) harus melalui delay 48 jam.
- Upgrade dapat dibatalkan oleh pemegang `CANCELLER_ROLE` selama delay berjalan.
- Tidak ada perubahan pada alur owner functions (setOperator, pause, setRiskModule, dll) — tetap langsung ke multisig.
- Deployment spoke contracts di setiap chain punya TimeLock-nya sendiri (tidak cross-chain govern).
- Mainnet production bisa di-deploy dengan konfigurasi TimeLock yang benar sejak awal.

---

## 3. Non-Goals

- **Bukan** goal: TimeLock untuk semua owner functions (setOperator, setRiskModule, pause, dll).
- **Bukan** goal: DAO governance atau on-chain voting.
- **Bukan** goal: mengubah delay untuk emergency pause — `pause()` tetap langsung tanpa delay.
- **Bukan** goal: TimeLock untuk testnet / devnet (testnet dapat skip TimeLock demi kecepatan iterasi).

---

## 4. Actors

| Actor | Role | Kemampuan |
|-------|------|-----------|
| **Multisig** | `PROPOSER_ROLE` + `CANCELLER_ROLE` | Mengajukan dan membatalkan upgrade |
| **Multisig** | `EXECUTOR_ROLE` | Mengeksekusi upgrade setelah delay |
| **Anyone** (opsional) | `EXECUTOR_ROLE` terbuka | Jika `EXECUTOR_ROLE` di-set ke `address(0)`, siapapun bisa eksekusi setelah delay |
| **TimeLockController** | Self-admin | Setelah `ADMIN_ROLE` direnounce, tidak ada yang bisa ubah parameter TimeLock |

---

## 5. Contract Coverage

### 5.1 Hub Contracts (Arbitrum) — Satu TimeLockController

Semua 8 ProxyAdmin hub dikontrol oleh satu TimeLock instance:

| Contract | Proxy | ProxyAdmin Owner Sekarang | ProxyAdmin Owner Setelah |
|----------|-------|--------------------------|--------------------------|
| `BalanceLedger` | ✅ Proxy | EOA/Multisig | TimeLock (hub) |
| `Centuari` | ✅ Proxy | EOA/Multisig | TimeLock (hub) |
| `Settlement` | ✅ Proxy | EOA/Multisig | TimeLock (hub) |
| `CollateralManager` | ✅ Proxy | EOA/Multisig | TimeLock (hub) |
| `HubDepositor` | ✅ Proxy | EOA/Multisig | TimeLock (hub) |
| `WithdrawalRegistry` | ✅ Proxy | EOA/Multisig | TimeLock (hub) |
| `HubIntentSettler` | ✅ Proxy | EOA/Multisig | TimeLock (hub) |
| `SettlementLedger` | ✅ Proxy | EOA/Multisig | TimeLock (hub) |

### 5.2 Spoke Contracts (per chain) — Satu TimeLockController per Chain

Setiap spoke chain deploy satu TimeLock instance sendiri:

| Contract | Proxy | ProxyAdmin Owner Setelah |
|----------|-------|--------------------------|
| `SpokeDepositGateway` | ✅ Proxy | TimeLock (spoke-chain) |
| `SpokeVaultStable` | ✅ Proxy | TimeLock (spoke-chain) |
| `SpokePayout` | ✅ Proxy | TimeLock (spoke-chain) |

### 5.3 Tidak Membutuhkan TimeLock

| Contract | Alasan |
|----------|--------|
| `RiskModuleStub` | Bukan proxy, deployed langsung (stateless) |
| `CentuariBondERC20` | Immutable per market — bukan upgradeable |
| `CentuariBondERC20Factory` | Bukan proxy |
| `MockTokens` | Testnet only |
| `Faucet` | Testnet only |

---

## 6. TimeLockController Configuration

```
minDelay   : 172800 (48 jam dalam detik)
proposers  : [MULTISIG_ADDRESS]
executors  : [MULTISIG_ADDRESS]  
             (atau address(0) untuk open execution setelah delay)
admin      : address(0) — direnounce setelah deploy
```

> **Catatan:** Jika `executors` di-set ke `address(0)`, siapapun bisa mengeksekusi operasi yang sudah melewati delay — ini mengurangi risiko DoS pada execution tapi menghilangkan kontrol siapa yang eksekusi. Keputusan ini perlu dikonfirmasi sebelum mainnet.

---

## 7. Upgrade Flow (Setelah TimeLock)

### Sebelum (tanpa TimeLock)
```
Multisig → ProxyAdmin.upgradeAndCall(proxy, newImpl, "") → ✅ Langsung aktif
```

### Setelah (dengan TimeLock)
```
Step 1 — Schedule:
  Multisig → TimeLock.schedule(
      target      = address(proxyAdmin),
      value       = 0,
      data        = abi.encodeCall(ProxyAdmin.upgradeAndCall, (proxy, newImpl, "")),
      predecessor = bytes32(0),
      salt        = keccak256(abi.encode("upgrade-settlement-v2")),
      delay       = 172800   // 48 jam
  )

  ← Emit: CallScheduled(id, index, target, value, data, predecessor, delay) ←
  ← Siapapun dapat melihat upgrade yang akan datang ←

Step 2 — (Tunggu 48 jam) —

Step 3 — Execute:
  Multisig → TimeLock.execute(
      target, value, data, predecessor, salt
  )
  → ✅ Upgrade aktif
```

### Pembatalan
```
Kapan saja selama delay:
  Multisig → TimeLock.cancel(operationId)
  → ❌ Upgrade dibatalkan, kembali ke implementation lama
```

---

## 8. Files yang Perlu Dibuat

| File | Deskripsi |
|------|-----------|
| `script/DeployTimeLock.s.sol` | Deploy TimelockController (hub). Parameter: `minDelay`, `proposers[]`, `executors[]` |
| `script/DeploySpokeTimeLock.s.sol` | Deploy TimelockController (spoke, per chain). Sama dengan hub tapi berdiri sendiri |
| `script/ScheduleUpgrade.s.sol` | Helper: encode + schedule upgrade operation via TimeLock |
| `script/ExecuteUpgrade.s.sol` | Helper: execute scheduled upgrade setelah delay |
| `script/CancelUpgrade.s.sol` | Helper: batalkan operasi yang sudah di-schedule |

---

## 9. Files yang Perlu Diubah

### 9.1 Script Deploy (parameter `proxyAdminOwner`)

| File | Perubahan |
|------|-----------|
| `script/DeployBalanceLedger.s.sol` | `proxyAdminOwner` di-pass sebagai TimeLock address (bukan EOA) |
| `script/DeployCentuari.s.sol` | Sama |
| `script/DeploySettlement.s.sol` | Sama |
| `script/DeployCollateralStack.s.sol` | Sama |
| `script/DeployHubDepositor.s.sol` | Sama |
| `script/DeployCrossChainHub.s.sol` | Sama (untuk WithdrawalRegistry, HubIntentSettler, SettlementLedger) |
| `script/DeploySpokeContracts.s.sol` | `proxyAdminOwner` = spoke TimeLock address |

> Script deploy sendiri tidak berubah secara logika — hanya parameter `proxyAdminOwner` yang di-pass dari env berubah dari `DEPLOYER_ADDRESS` ke `TIMELOCK_ADDRESS`.

### 9.2 Upgrade Scripts (alur berubah total)

| File | Perubahan |
|------|-----------|
| `script/UpgradeSettlement.s.sol` | Ganti `ProxyAdmin.upgradeAndCall()` langsung → encode calldata + `TimeLock.schedule()` |
| `script/UpgradeCollateralManager.s.sol` | Sama |
| `script/UpgradeWithdrawalRegistry.s.sol` | Sama |
| *(semua Upgrade\*.s.sol mendatang)* | Harus menggunakan pola TimeLock schedule/execute |

### 9.3 Shell Scripts

| File | Perubahan |
|------|-----------|
| `bin/run-all.sh` | Tambah Step 0: `DeployTimeLock` sebelum semua langkah lain. Tambah env var `TIMELOCK_ADDRESS`. Pass `TIMELOCK_ADDRESS` sebagai `proxyAdminOwner` ke semua deploy script |
| `bin/deploy-spoke.sh` | Tambah deploy spoke TimeLock di awal, pass alamatnya ke semua spoke deploy script |

### 9.4 Environment Variables (`.env`)

Tambahkan variabel baru:
```bash
TIMELOCK_ADDRESS=           # Hub TimeLock address (di-set setelah DeployTimeLock)
TIMELOCK_PROPOSER=          # Multisig address yang jadi PROPOSER
TIMELOCK_EXECUTOR=          # Multisig address yang jadi EXECUTOR (atau address(0))
TIMELOCK_MIN_DELAY=172800   # 48 jam dalam detik
```

---

## 10. Deployment Summary JSON

`deployments/deploy-<network>-latest.json` perlu field baru:

```json
{
  "timelockAddress": "0x...",
  "timelockMinDelay": 172800,
  "timelockProposer": "0x...",
  "timelockExecutor": "0x..."
}
```

---

## 11. Urutan Deployment yang Diperbarui (run-all.sh)

```
Step 0  (BARU): DeployTimeLock
Step 1:         DeployMockTokens
Step 2:         DeployFaucet
Step 3:         DeployBalanceLedger       ← proxyAdminOwner = TIMELOCK_ADDRESS
Step 4:         DeployCentuari            ← proxyAdminOwner = TIMELOCK_ADDRESS
Step 5:         DeployBondFactory
Step 6:         ConfigureBondFactory
Step 7:         DeployHubDepositor        ← proxyAdminOwner = TIMELOCK_ADDRESS
Step 8:         ConfigureHubDepositor
Step 9:         DeployCollateralStack     ← proxyAdminOwner = TIMELOCK_ADDRESS
Step 10:        ConfigureBalanceLedger
Step 11:        DeploySettlement          ← proxyAdminOwner = TIMELOCK_ADDRESS
Step 12:        ConfigureBalanceLedger
Step 13:        SetSettlement on Centuari
Step 14:        UpgradeSettlement         ← via TimeLock.schedule() (jika ada)
Step 15:        SetOperators
Step 16:        DeployCrossChainHub       ← proxyAdminOwner = TIMELOCK_ADDRESS
Step 17:        ConfigureBalanceLedger
Step 18:        ConfigureHubDepositorAuth
```

---

## 12. Keputusan yang Masih Perlu Dikonfirmasi

| # | Keputusan | Opsi |
|---|-----------|------|
| 1 | **`EXECUTOR_ROLE` open atau closed?** | `address(0)` = siapapun bisa eksekusi setelah delay / Multisig = hanya multisig yang bisa eksekusi |
| 2 | **Testnet skip TimeLock?** | Ya (tambah flag `--skip-timelock` di run-all.sh untuk testnet) / Tidak (konsisten antara testnet & mainnet) |
| 3 | **TimeLock delay testnet?** | Sama 48 jam / Shorter (misal 5 menit) untuk kemudahan testing |

---

## 13. Risiko & Mitigasi

| Risiko | Mitigasi |
|--------|---------|
| Upgrade mendesak (critical bug) tertahan 48 jam | Tetap bisa `pause()` langsung tanpa TimeLock untuk halt protocol sementara |
| Multisig key compromise → schedule upgrade berbahaya | `CANCELLER_ROLE` bisa batalkan. Jika multisig compromise total, ini tidak cukup — pertimbangkan guardian multisig terpisah |
| Lupa eksekusi setelah delay expired | `OperationState` tetap `Ready` sampai di-eksekusi atau di-cancel — tidak ada expiry otomatis |
| Salah encode calldata saat schedule | Test di testnet dulu; gunakan `TimeLock.getOperationState(id)` untuk verifikasi |

---

## 14. Success Criteria

- [ ] `DeployTimeLock.s.sol` berhasil deploy TimelockController di hub chain
- [ ] `DeploySpokeTimeLock.s.sol` berhasil deploy per spoke chain
- [ ] Semua ProxyAdmin (hub) verify `owner() == TIMELOCK_ADDRESS`
- [ ] Semua ProxyAdmin (spoke) verify `owner() == SPOKE_TIMELOCK_ADDRESS`
- [ ] `ScheduleUpgrade.s.sol` berhasil schedule upgrade di local fork
- [ ] Setelah 48 jam (warp `vm.warp` di fork test), `ExecuteUpgrade.s.sol` berhasil eksekusi
- [ ] `CancelUpgrade.s.sol` berhasil cancel upgrade yang sudah di-schedule
- [ ] `run-all.sh` end-to-end berhasil dengan `TIMELOCK_ADDRESS` sebagai `proxyAdminOwner`
