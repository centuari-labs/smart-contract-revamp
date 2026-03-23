# /audit-contract [ContractName]

Perform a full security audit on a Centuari smart contract.

## Steps

1. **Explore** — Use the `explorer` agent to map the contract, its dependencies, inheritance chain, and existing test file.

2. **Manual Security Review** — Run the `security-review` skill on the contract. Execute the full 10-point checklist: CEI, reentrancy guards, oracle freshness, interest accrual ordering, liquidation bounds, collateral normalization, access control, unchecked blocks, storage layout, static analysis.

3. **Static Analysis** — If slither is installed, run:
   ```bash
   slither src/core/[ContractName].sol --filter-paths "lib/|test/|script/" 2>&1 | head -100
   ```
   If not installed, note: "Static analysis not configured — recommend installing slither."

4. **Deep Security Audit** — Use the `security-auditor` agent (Opus) with:
   - The manual review findings from step 2
   - The contract source code
   - The CLAUDE.md Security Invariants section
   - Ask it to check every invariant explicitly and run the full checklist

5. **Triage** — For every CRITICAL or HIGH finding:
   - Present to the user with the attack vector description
   - Ask for confirmation before proceeding with fixes
   - Do NOT auto-fix CRITICAL/HIGH issues without user approval

6. **Fix** — For approved fixes, use the `implementer` agent. Each fix must:
   - Be minimal (change only what's needed)
   - Maintain all security invariants
   - Include a comment referencing the finding (e.g., `// H-01 fix: check answer > 0`)

7. **Re-audit** — After fixes, run the `security-auditor` agent again on the changed files. Verify all CRITICAL and HIGH findings are resolved.

8. **Update CLAUDE.md** — If a new vulnerability pattern was found:
   - Add to Known Vulnerabilities section with date
   - Add any new invariant to Security Invariants section
   - Add any new gotcha to Gotchas section

9. **Return** — Full findings list, fixes applied, invariants verified, final verdict.
