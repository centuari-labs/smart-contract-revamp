---
name: solidity-patterns
description: >
  Invoke when writing any new Solidity code, modifying existing contract
  logic, or when unsure which pattern to use for a given problem. Provides
  Centuari-specific coding standards derived from the actual codebase.
allowed-tools: Read, Write, Edit, Glob
---

# Centuari Solidity Coding Patterns

All patterns derived from the actual codebase. Match these exactly when writing new code.

## Custom Errors (not require strings)

```solidity
// In interface (e.g., ICentuari.sol):
error ZeroAddress();
error InvalidAmount();
error Unauthorized();
error ContractPaused();
error InvalidMaturity();
error AlreadySettled(bytes32 matchId);
error InsufficientFunds();
error BondTokenNotFound();
error NotYetMatured();

// In contract (e.g., LiquidationEngine.sol):
error PositionHealthy(uint256 healthFactor);
error GracePeriodNotExpired(uint256 deadline, uint256 current);
error ExceedsMaxDebtCoverage(uint256 requested, uint256 max);
error PriceFeedStale();
error CollateralNotActive();
error LiquidatorNotApproved(address liquidator, address asset);

// Usage:
if (msg.sender != _operator) revert Unauthorized();
if (amount == 0) revert InvalidAmount();
```

## Events

```solidity
// State change events — always indexed on key addresses/IDs:
event MarketCreated(bytes32 indexed marketId, address indexed loanToken, uint256 maturity);
event LendPositionCreated(bytes32 indexed marketId, address indexed lender, address bondToken, uint256 cbtAmount, uint256 principal, uint256 rate);
event BorrowPositionCreated(bytes32 indexed marketId, address indexed borrower, uint256 principal, uint256 debt, uint256 rate);
event SettlementUpdated(address indexed oldSettlement, address indexed newSettlement);

// Admin events:
event Paused(address indexed account);
event Unpaused(address indexed account);
event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
event AuthorizedWriterUpdated(address indexed writer, bool authorized);
```

## Modifiers

```solidity
// Access control — revert with custom error:
modifier onlySettlement() {
    if (msg.sender != _settlement) revert Unauthorized();
    _;
}
modifier onlyOperator() {
    if (msg.sender != _operator) revert Unauthorized();
    _;
}
modifier onlyAuthorized() {
    if (!_authorizedWriters[msg.sender]) revert Unauthorized();
    _;
}
modifier onlyMultisig() {
    if (msg.sender != _multisig) revert Unauthorized();
    _;
}
modifier onlyCentuari() {
    if (centuariContract == address(0)) revert Unauthorized();
    if (msg.sender != centuariContract) revert Unauthorized();
    _;
}

// State guards:
modifier whenNotPaused() {
    if (_paused) revert ContractPaused();
    _;
}
modifier nonZeroAmount(uint256 amount) {
    if (amount == 0) revert InvalidAmount();
    _;
}
modifier onlySupportedToken(address token) {
    if (!supportedToken[token]) revert Unauthorized();
    _;
}
```

## Storage Organization (Upgradeable Contracts)

```solidity
// Always separate storage from logic:
// FooStorage.sol:
abstract contract FooStorage {
    // ============ Constants ============
    uint256 internal constant RATE_PRECISION = 10000;

    // ============ Storage Variables ============
    address internal _dependency;
    mapping(bytes32 => uint256) internal _data;
    bool internal _paused;

    // ============ Storage Gap ============
    /// @dev Reduce when adding new variables
    uint256[47] private __gap;
}

// Foo.sol:
contract Foo is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, FooStorage, IFoo {
    constructor() { _disableInitializers(); }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
    }
}
```

## OpenZeppelin v5 Imports

```solidity
// Upgradeable base contracts:
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// Custom reentrancy guard (ERC7201 namespaced):
import {ReentrancyGuardUpgradeable} from "../../utils/ReentrancyGuardUpgradeable.sol";

// Non-upgradeable (used in Treasury, CBT):
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Token safety:
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Crypto:
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// Proxy deployment:
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
```

## Token Transfer Pattern

```solidity
using SafeERC20 for IERC20;

// Deposit (pull from user):
IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

// Withdraw (push to user):
IERC20(asset).safeTransfer(msg.sender, amount);

// Approve for adapter:
IERC20(asset).forceApprove(adapter, amount);

// NEVER use raw transfer():
// token.transfer(to, amount);  // BAD — no return value check
```

## Fixed-Point Math

```solidity
uint256 internal constant RATE_PRECISION = 10000;        // Basis points
uint256 internal constant SECONDS_PER_YEAR = 365 days;   // 31536000
uint256 internal constant HF_PRECISION = 1e18;           // Health factor
uint256 internal constant BPS_DENOMINATOR = 10000;        // Basis points
uint256 internal constant CBT_TOLERANCE = 1;              // ±1 wei for CBT validation

// Interest computation:
uint256 interest = (principal * rateBPS * elapsedSeconds) / (RATE_PRECISION * SECONDS_PER_YEAR);

// Health factor:
uint256 hf = (weightedCollateral * HF_PRECISION) / totalDebt;

// Bonus computation:
uint256 debtWithBonus = debtToCover * (BPS_DENOMINATOR + bonusBPS) / BPS_DENOMINATOR;

// Price normalization (Chainlink 8 decimals to 18):
uint256 priceUSD = uint256(answer) * (10 ** (18 - feedDecimals));
```

## NatSpec Style

```solidity
/// @title Centuari
/// @notice Manages lending and borrowing positions for fixed-rate markets
/// @dev Deployed behind ERC1967 proxy. Markets identified by (loanToken, maturity).

/// @notice Process the lender's position
/// @dev CBT = effectivePrincipal + interest. Interest uses seconds-based day count.
/// @param marketId The market identifier
/// @param lender The lender address
/// @param principal The original matched principal
/// @return cbtAmount The CBT issued to the lender
function _processLendPosition(...) internal returns (uint256 cbtAmount) {
```

## Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Contracts | PascalCase | `CentuariEndpoint` |
| Interfaces | `I` prefix | `ICentuariEndpoint` |
| Storage | `*Storage` suffix | `CentuariEndpointStorage` |
| External functions | camelCase | `settleMatch`, `withdrawLendPosition` |
| Internal functions | `_` prefix | `_processMatch`, `_computeExpectedCBT` |
| Constants | SCREAMING_SNAKE | `RATE_PRECISION`, `MAX_RATE_BPS` |
| Storage variables | `_` prefix | `_settlement`, `_paused` |
| Events | PascalCase | `SettlementBatchConfirmed` |
| Errors | PascalCase | `NonceTooLow` |
| Modifiers | camelCase | `onlySettlement`, `whenNotPaused` |
