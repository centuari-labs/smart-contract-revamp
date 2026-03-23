# /fix-bug [description]

Fix a bug in the Centuari smart contract codebase.

## Steps

1. **Classify** — Run the `security-review` skill first. Is this:
   - **Security vulnerability** — could lead to fund loss, unauthorized access, or protocol insolvency
   - **Functional bug** — incorrect behavior but no direct security impact

2. **If security vulnerability** — Use the `security-auditor` agent (Opus) IMMEDIATELY to understand the full blast radius before touching any code:
   - What is the root cause?
   - What other code paths are affected?
   - Can this be exploited before the fix ships?
   - Is there a temporary mitigation (e.g., pause)?

3. **If functional bug** — Confirm root cause in the main conversation:
   - Read the relevant code
   - Trace the execution path
   - Identify the exact line(s) causing the issue

4. **Fix** — Use the `implementer` agent for the minimum fix:
   - Change only what's necessary to fix the bug
   - Do NOT refactor surrounding code
   - Do NOT add features or improvements
   - Add a comment referencing the bug (e.g., `// Fix: check maturity > block.timestamp before processing`)

5. **Regression Test** — Use the `test-writer` agent:
   - Write a test that reproduces the original bug (should fail without the fix)
   - Write a test that verifies the fix works
   - Run `forge test --match-test [test_name]` to verify

6. **Security Review** — Run the `security-review` skill on the fix.

7. **If original issue was security vulnerability** — Use the `security-auditor` agent (Opus) again to verify:
   - The fix completely closes the attack vector
   - No new attack vectors were introduced by the fix
   - All relevant security invariants pass

8. **Update CLAUDE.md** — Append to Gotchas section with date:
   ```
   - [DATE] [Description of the bug and the non-obvious lesson learned]
   ```
   If it was a security vulnerability, also update Known Vulnerabilities.
