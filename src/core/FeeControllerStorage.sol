// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title FeeControllerStorage
/// @notice Storage layout for FeeController upgradeable contract
/// @dev NEVER reorder or remove variables — only append before __gap and reduce gap size.
abstract contract FeeControllerStorage {
    // ============ Dependencies ============

    /// @notice BalanceLedger contract for executing fee transfers
    address internal _balanceLedger;

    /// @notice Protocol treasury address — receives all protocol fee revenue
    address internal _protocolTreasury;

    /// @notice CentuariEndpoint — only caller for validateAndExecuteFees
    address internal _centuariEndpoint;

    // ============ Fee Parameters ============

    /// @notice Taker fee as BPS of gross interest (e.g., 500 = 5%)
    uint256 internal _takerFeeBPS;

    /// @notice Maker rebate as BPS of gross interest (e.g., 300 = 3%)
    uint256 internal _makerRebateBPS;

    /// @notice Rollover fee as BPS of yield earned (e.g., 50 = 0.5%)
    uint256 internal _rolloverFeeBPS;

    /// @notice Refinance fee as BPS of interest accrued (e.g., 50 = 0.5%)
    uint256 internal _refinanceFeeBPS;

    /// @notice Flat settlement fee per side, in asset decimals (e.g., 100000 = $0.10 USDC at 6 decimals)
    uint256 internal _settlementFeePerSide;

    // ============ Governance Timelock ============

    /// @notice Pending parameter values awaiting timelock expiry
    /// @dev paramHash => new value
    mapping(bytes32 => uint256) internal _pendingParamValues;

    /// @notice Timelock end timestamps for pending parameter updates
    /// @dev paramHash => timestamp when update can be applied
    mapping(bytes32 => uint256) internal _paramTimelockEnd;

    // ============ State ============

    /// @notice Paused state
    bool internal _paused;

    // ============ Constants ============

    /// @notice Timelock duration for fee parameter changes (48 hours)
    uint256 internal constant TIMELOCK_DURATION = 48 hours;

    /// @notice Maximum taker fee: 10% of interest
    uint256 internal constant MAX_TAKER_FEE_BPS = 1000;

    /// @notice Maximum maker rebate: 5% of interest
    uint256 internal constant MAX_MAKER_REBATE_BPS = 500;

    /// @notice Maximum rollover/refinance fee: 5% of yield
    uint256 internal constant MAX_ROLLOVER_FEE_BPS = 500;

    /// @notice Maximum settlement fee per side: $1.00 (1_000_000 at 6 decimals)
    uint256 internal constant MAX_SETTLEMENT_FEE = 1_000_000;

    /// @notice Basis points precision
    uint256 internal constant BPS_PRECISION = 10_000;

    /// @notice Rate precision (same as BPS_PRECISION for interest rates)
    uint256 internal constant RATE_PRECISION = 10_000;

    /// @notice Seconds per year for interest computation
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    // ============ Reason Hashes ============

    bytes32 internal constant REASON_TAKER_FEE = keccak256("TAKER_FEE");
    bytes32 internal constant REASON_MAKER_REBATE = keccak256("MAKER_REBATE");
    bytes32 internal constant REASON_SETTLEMENT_FEE = keccak256("SETTLEMENT_FEE");
    bytes32 internal constant REASON_ROLLOVER_FEE = keccak256("ROLLOVER_FEE");
    bytes32 internal constant REASON_REFINANCE_FEE = keccak256("REFINANCE_FEE");
    bytes32 internal constant REASON_PROTOCOL_REVENUE = keccak256("PROTOCOL_REVENUE");

    // ============ Parameter IDs ============

    bytes32 internal constant PARAM_TAKER_FEE = keccak256("TAKER_FEE_BPS");
    bytes32 internal constant PARAM_MAKER_REBATE = keccak256("MAKER_REBATE_BPS");
    bytes32 internal constant PARAM_ROLLOVER_FEE = keccak256("ROLLOVER_FEE_BPS");
    bytes32 internal constant PARAM_REFINANCE_FEE = keccak256("REFINANCE_FEE_BPS");
    bytes32 internal constant PARAM_SETTLEMENT_FEE = keccak256("SETTLEMENT_FEE_PER_SIDE");

    // ============ Gap ============

    /// @dev Reserved storage for future upgrades
    uint256[35] private __gap;
}
