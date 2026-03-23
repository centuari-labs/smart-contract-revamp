# /review-pr [changed files or PR number]

Review changed files before merge.

## Steps

1. **Classify all changed files** by risk level:

   **Critical path** (mandatory Opus audit):
   - `LiquidationEngine.sol` — liquidation logic
   - `RiskModule.sol` — health factor, borrow validation
   - `CentuariEndpoint.sol` — settlement, CBT minting, signature verification
   - `BalanceLedger.sol` — balance state transitions, collateral operations
   - `CollateralRegistry.sol` — attestation processing, price updates
   - `Centuari.sol` — interest computation, position management
   - `YieldRouter.sol` — capital deployment, recall, InsuranceReserve
   - `AssetBehaviorRegistry.sol` — LTV, liquidation thresholds
   - Any `*Storage.sol` file — storage layout changes

   **Standard path** (Sonnet review sufficient):
   - Periphery contracts (Router, Oracle, WithdrawalRegistry)
   - Mock contracts
   - Test files
   - Scripts
   - NatSpec/comment changes only
   - Event/error additions with no logic change

2. **Run security-review skill** on ALL changed `.sol` files in `src/`.

3. **For critical path files** — Use the `security-auditor` agent (Opus). No exceptions. Provide:
   - The diff (changed lines)
   - The full current file
   - Which security invariants could be affected
   - Any storage layout changes

4. **For standard path files** — Review in the main conversation:
   - Verify code follows `solidity-patterns` skill standards
   - Check NatSpec completeness
   - Verify events emitted for state changes
   - Check test coverage for new functions

5. **Test verification** — Run `forge test` on all changed test files. All must pass.

6. **Storage layout check** — If any `*Storage.sol` was changed:
   - Verify variables only appended
   - Verify `__gap` reduced by the number of new slots
   - No variable reordering or removal

7. **All CRITICALs and HIGHs must be fixed** before approval.

8. **Return**:
   ```
   RISK CLASSIFICATION:
   - [file] — [critical/standard] — [reason]

   FINDINGS:
   - [severity] [file:line] [description]

   VERDICT: APPROVE / REQUEST CHANGES
   ```
