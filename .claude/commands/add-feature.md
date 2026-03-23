# /add-feature [feature description]

Implement a new feature in the Centuari smart contract codebase.

## Steps

1. **Explore** — Use the `explorer` agent to find all contracts and tests affected by this feature.

2. **Draft Spec** — Document:
   - What changes are needed (new functions, storage vars, events, errors)
   - Which contracts are modified
   - Which security invariants from CLAUDE.md are affected
   - What the expected gas impact is

3. **Security Gate** — Does this feature touch any of these?
   - Liquidation logic
   - Health factor calculation
   - Interest accrual formula
   - Oracle integration
   - Collateral management
   - Access control architecture

   **If YES** → Use the `architect` agent (Opus) to design the feature first. Get a concrete implementation spec with security analysis before writing code.

   **If NO** → Proceed to step 5.

4. **Confirm with user** — Present the implementation plan. Wait for approval before writing code.

5. **Implement** — Use the `solidity-patterns` skill for reference, then the `implementer` agent. Requirements:
   - Match existing code patterns exactly
   - Add NatSpec using `natspec-writer` skill standards
   - Enforce CEI on all state-changing functions
   - Use SafeERC20 for all token transfers
   - Emit events for all state changes
   - Custom errors (not require strings)

6. **Write Tests** — Use the `test-writer` agent. Mandatory test types:
   - Happy path
   - All revert cases
   - Boundary conditions
   - Fuzz test for any numeric input
   - Economic attack simulation (if financial function)

7. **Security Review** — Run the `security-review` skill on all changed contracts.

8. **Security Audit** — Use the `security-auditor` agent (Opus). **Mandatory, no exceptions.** Even for "simple" features — the agent catches things Sonnet misses.

9. **Fix Findings** — All CRITICAL and HIGH must be fixed before returning. Re-run security-auditor after fixes.

10. **Return** — What was built, test results, audit verdict, any new invariants added to CLAUDE.md.
