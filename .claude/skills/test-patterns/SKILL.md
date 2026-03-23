---
name: test-patterns
description: >
  Invoke when writing any Foundry test for Centuari contracts. Provides
  the exact test patterns, helpers, and fixtures used in this test suite.
allowed-tools: Read, Write, Edit, Bash, Glob
---

# Centuari Test Patterns (Foundry)

## Test File Location

- Unit tests: `test/core/{ContractName}.t.sol`
- Integration tests: `test/integration/{FlowName}.t.sol`
- Original settlement tests: `test/centuari/Centuari.t.sol`, `test/settlement/Settlement.t.sol`
- Mock tests: `test/mocks/{MockName}.t.sol`

## setUp() Pattern

### Upgradeable Contract (with TransparentUpgradeableProxy)

```solidity
import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {CentuariEndpoint} from "../../src/core/CentuariEndpoint.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";

contract CentuariEndpointTest is Test {
    CentuariEndpoint public endpoint;
    BalanceLedger public ledger;

    address public owner = address(0x1);
    address public multisig = address(0x2);
    uint256 public signerPrivateKey = 0xA11CE;
    address public signer;
    address public lender = address(0x10);
    address public borrower = address(0x20);
    address public usdc = address(0x100);

    function setUp() public {
        signer = vm.addr(signerPrivateKey);

        // Deploy behind proxy
        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(
            address(new BalanceLedger()), owner,
            abi.encodeCall(BalanceLedger.initialize, (owner))
        )));

        endpoint = CentuariEndpoint(address(new TransparentUpgradeableProxy(
            address(new CentuariEndpoint()), owner,
            abi.encodeCall(CentuariEndpoint.initialize, (owner, signer, multisig, address(ledger)))
        )));

        // Wire dependencies
        vm.prank(owner);
        ledger.setAuthorizedWriter(address(endpoint), true);

        // Seed balances
        vm.prank(owner);
        ledger.setAuthorizedWriter(address(this), true);
        ledger.credit(lender, usdc, 100_000e6);
    }
}
```

### Non-Upgradeable Contract (Treasury)

```solidity
contract TreasuryTest is Test {
    Treasury public treasury;
    MockToken public usdc;

    address public admin = address(0x1);
    address public user = address(0x10);

    function setUp() public {
        vm.prank(admin);
        treasury = new Treasury();

        usdc = new MockToken("USDC", "USDC", 6);

        vm.prank(admin);
        treasury.grantRole(treasury.TOKEN_MANAGER_ROLE(), admin);
        vm.prank(admin);
        treasury.setSupportedToken(address(usdc), true);
    }
}
```

## Mock Contracts

```solidity
// MockToken — mint any amount for testing
MockToken usdc = new MockToken("USDC", "USDC", 6);
usdc.mint(user, 1_000_000e6);

// MockChainlinkFeed — configurable price
MockChainlinkFeed feed = new MockChainlinkFeed(8); // 8 decimals
feed.setAnswer(2000e8); // $2000

// Set price and timestamp for staleness testing
feed.setRoundData(1, 2000e8, block.timestamp, block.timestamp, 1);
```

## ECDSA Signing Pattern (for CentuariEndpoint)

```solidity
using ECDSA for bytes32;
using MessageHashUtils for bytes32;

function _signBatch(ICentuariEndpoint.SettlementBatch memory batch) internal view returns (bytes memory) {
    bytes32 batchDigest = keccak256(abi.encode(
        batch.nonce, batch.timestamp, batch.batchHash,
        batch.matches.length, batch.rollovers.length,
        batch.refinances.length, batch.liquidations.length,
        batch.returnSettlements.length, batch.graceStarts.length
    ));
    bytes32 ethSignedHash = batchDigest.toEthSignedMessageHash();
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedHash);
    return abi.encodePacked(r, s, v);
}
```

## Revert Testing with Custom Errors

```solidity
// Expect specific custom error
vm.expectRevert(ICentuari.Unauthorized.selector);
centuari.settleMatch(...);

// Expect error with parameters
vm.expectRevert(abi.encodeWithSelector(
    ICentuariEndpoint.NonceTooLow.selector, expectedNonce, actualNonce
));
endpoint.submitSettlementBatch(batch, sig);

// Expect generic revert
vm.expectRevert();
foo.bar();
```

## Event Testing

```solidity
// Expect exact event
vm.expectEmit(true, true, true, true);
emit ICentuari.MarketCreated(expectedMarketId, address(usdc), maturity);
centuari.settleMatch(...);

// Check indexed params only
vm.expectEmit(true, true, false, false);
emit ICentuari.LendPositionCreated(marketId, lender, address(0), 0, 0, 0);
```

## Prank Pattern (caller impersonation)

```solidity
// Single call
vm.prank(owner);
foo.adminFunction();

// Multiple calls from same address
vm.startPrank(operator);
settlement.settleMatch(match1);
settlement.settleMatch(match2);
vm.stopPrank();
```

## Fuzz Test Pattern

```solidity
function testFuzz_interestComputation(
    uint256 principal,
    uint256 rate,
    uint256 duration
) public {
    // Bound inputs to realistic ranges
    principal = bound(principal, 1e6, 1e30);     // $1 to $1T (6 dec)
    rate = bound(rate, 1, 10000);                 // 0.01% to 100%
    duration = bound(duration, 1, 365 days);      // 1 second to 1 year

    uint256 start = block.timestamp;
    uint256 maturity = start + duration;

    uint256 interest = centuari._interestWithDayCount(principal, rate, start, maturity);

    // Invariant: interest >= 0
    assertGe(interest, 0, "Interest must be non-negative");

    // Invariant: interest <= principal (for rate <= 100% and duration <= 1 year)
    assertLe(interest, principal, "Interest cannot exceed principal for 1 year at 100%");

    // Invariant: higher rate = higher interest (monotonic)
    if (rate > 1) {
        uint256 lowerInterest = centuari._interestWithDayCount(principal, rate - 1, start, maturity);
        assertGe(interest, lowerInterest, "Interest must increase with rate");
    }
}
```

## Missing Tests (Priority — from Step 1 findings)

These security-critical paths have NO test coverage:

1. **SecurityInvariants.t.sol** — All 16 tests are `assertTrue(true)` stubs. Need real enforcement tests.
2. **Fuzz tests on financial math** — `_interestWithDayCount`, `_computeExpectedCBT`, `_computeSeizure`
3. **Liquidation edge cases** — over-liquidation, flash-loan griefing, stale oracle rejection
4. **BalanceLedger.withdraw() HF check** — no test verifying withdrawal is blocked when it would break HF
5. **RiskModule negative/zero price** — no test for `latestRoundData` returning <= 0
6. **CentuariEndpoint CBT mint tolerance** — no fuzz test on ±1 wei boundary
7. **Cross-contract reentrancy** — no test for reentrancy via BalanceLedger shared state
8. **Grace period boundary** — no test for liquidation at exactly `gracePeriodEnds` timestamp
