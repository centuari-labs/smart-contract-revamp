# /improve-workflow

Review and improve the Claude Code workflow infrastructure for this repo.

## Steps

1. **Audit skill coverage** — For each skill and agent:
   - Is it still accurate given codebase changes?
   - Are there new patterns not captured?
   - Are there deprecated patterns still listed?

2. **Check vulnerability coverage** — Review CLAUDE.md Known Vulnerabilities:
   - Are there new attack vectors discovered in the DeFi ecosystem since last update?
   - Are all vulnerabilities found during audits documented?
   - Are mitigations still accurate?

3. **Check invariant coverage** — Review CLAUDE.md Security Invariants:
   - Are all invariants still enforced in code?
   - Are there new invariants that should be added?
   - Are any invariants obsolete due to architecture changes?

4. **Model generation check** — Are the model strings in agent definitions current?
   - `claude-sonnet-4-6` — is there a newer Sonnet?
   - `claude-opus-4-6` — is there a newer Opus?
   - Update all agent `model:` frontmatter if new generations exist

5. **Test gap analysis** — Run through test files:
   - Are there new contracts without test files?
   - Are there security-critical paths without fuzz tests?
   - Are SecurityInvariants.t.sol stubs still stubs?

6. **Present proposals** — Show user what changes are recommended, grouped by:
   - Security (update invariants, vulnerabilities)
   - Quality (update patterns, add missing tests)
   - Infrastructure (update model strings, fix stale references)

7. **Apply approved edits** — Use `implementer` agent for approved changes.

8. **Verify** — Confirm all files are valid and `forge build` still passes.
