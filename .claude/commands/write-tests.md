# /write-tests [ContractName or feature]

Write comprehensive tests for a Centuari contract or feature.

## Steps

1. **Explore** — Use the `explorer` agent to find:
   - The target contract source
   - Existing test file (if any)
   - Dependencies and mock contracts needed
   - Which functions lack test coverage

2. **Load patterns** — Reference the `test-patterns` skill for:
   - setUp() pattern (proxy deployment, role granting, balance seeding)
   - Mock usage (MockToken, MockChainlinkFeed)
   - ECDSA signing pattern (for CentuariEndpoint tests)
   - Revert testing with custom errors
   - Event testing with `vm.expectEmit`

3. **Write tests** — Use the `test-writer` agent. Mandatory test types:

   **For every function:**
   - Happy path — normal successful execution
   - Revert cases — every `revert`/`require` must have a test
   - Boundary conditions — exact thresholds, zero values, max values

   **For functions with numeric inputs:**
   - Fuzz test with `bound()` to realistic ranges
   - Invariant assertions (non-negative interest, monotonic HF, etc.)

   **For security-critical functions (liquidation, HF, interest, collateral):**
   - Invariant test — security property holds across all states
   - Attack simulation — known attack vector does NOT succeed
   - Oracle staleness rejection test
   - Reentrancy test (if applicable)

4. **Run tests**:
   ```bash
   forge test --match-contract [TestContract] -v
   ```
   ALL must pass before returning.

5. **Coverage check** (if configured):
   ```bash
   forge coverage --match-contract [TestContract]
   ```
   Report coverage delta.

6. **Return** — Tests written (count by category), test results, coverage report, any functions that couldn't be adequately tested.
