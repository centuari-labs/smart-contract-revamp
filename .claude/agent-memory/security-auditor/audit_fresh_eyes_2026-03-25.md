---
name: Fresh Eyes Audit 2026-03-25
description: Targeted audit of FeeController, CentuariRouter, CentuariRateOracle, WithdrawalRegistry, and cross-contract interactions. 2 CRITICAL, 3 HIGH, 5 MEDIUM findings. Focus on previously unexamined contracts.
type: project
---

## Fresh Eyes Audit — 2026-03-25

**Contracts**: FeeController.sol, CentuariRouter.sol, CentuariRateOracle.sol, WithdrawalRegistry.sol + cross-contract interactions

**VERDICT**: REQUEST CHANGES

### CRITICAL (2)
1. **FeeController.sol:129-137** — validateAndExecuteFees does not validate that no EXTRA transfers exist in FeeDistribution. A compromised engine signer can include additional credit entries in the transfers array that pass validation (only totalProtocolRevenue and specific transfers are checked). Creates unbacked BalanceLedger credits.
2. **WithdrawalRegistry.sol:57-61** — requestWithdrawal() debits user balance for instant withdrawals but never transfers ERC20 tokens. complete() also does not transfer. Same-chain withdrawals via this path permanently lose user funds.

### HIGH (3)
1. **CentuariRouter.sol:245-251** — setEndpoint(), setRateOracle(), setAssetBehaviorRegistry() have no timelock. Instant endpoint swap breaks Invariant #12.
2. **CentuariRateOracle.sol:68-83** — commitRateSnapshot has no nonce, ordering, or bounds checking against prior values. Captured signatures from rotated keys could manipulate CBT fair value oracle.
3. **Multiple contracts** — LiquidationEngine.setAuthorizedCaller(), WithdrawalRegistry.setAuthorizedCaller(), BalanceLedger.setRiskModule()/setAssetBehaviorRegistry(), RiskModule.setBalanceLedger()/setAssetBehaviorRegistry() all lack timelocks. 4th audit finding this pattern.

### MEDIUM (5)
1. CentuariRouter.sol:188-192 — Callback before CBT transfer (CEI violation in try block)
2. FeeController.sol:160-180 — Fee computation relies on engine using current on-chain params
3. CentuariRouter.sol:59 — Intent ID includes block.timestamp (no additional entropy)
4. WithdrawalRegistry.sol:105-116 — escalate() has no auth check, anyone can escalate any withdrawal
5. CentuariEndpoint.sol:293-326 — _processRefinances missing anchor rate bounds check (Invariant #15 partially enforced)

### LOW (3)
1. CentuariRateOracle.sol:107-109 — getCBTFairValue returns $1.00 on failure, masking errors
2. FeeController.sol:371 — Rollover yield computation may include non-yield principal
3. CentuariRouter.sol:81 — _submitterIntents array grows unboundedly
