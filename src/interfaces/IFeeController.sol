// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFeeController
/// @notice Generic fee controller interface for the Centuari protocol
/// @dev CentuariEndpoint delegates ALL fee logic to this interface.
///      The endpoint contains zero fee calculation logic.
///      Adding new fee types only requires upgrading the FeeController implementation.
interface IFeeController {
    // ============ Structs ============

    /// @notice A single ledger operation: credit or debit an address
    /// @param account The recipient (credit) or payer (debit)
    /// @param asset The token address (e.g., USDC)
    /// @param amount The amount in asset decimals
    /// @param isCredit True = credit to available balance, false = debit from available balance
    /// @param reason Keccak256 hash of reason string for event indexing (e.g., keccak256("TAKER_FEE"))
    struct FeeTransfer {
        address account;
        address asset;
        uint256 amount;
        bool isCredit;
        bytes32 reason;
    }

    /// @notice Complete fee distribution for one settlement operation
    /// @param operationId Links to the source operation (lendOrderId, positionId, etc.)
    /// @param operationType 0=MATCH, 1=ROLLOVER, 2=REFINANCE, 3=LIQUIDATION
    /// @param transfers All credit/debit operations for this fee distribution
    /// @param totalProtocolRevenue Sum going to protocol treasury (for validation)
    struct FeeDistribution {
        bytes32 operationId;
        uint8 operationType;
        FeeTransfer[] transfers;
        uint256 totalProtocolRevenue;
    }

    // ============ Fee Execution ============

    /// @notice Validate fee distributions against raw operation data and execute via BalanceLedger
    /// @dev Called by CentuariEndpoint during batch processing.
    ///      Re-derives expected fees from operationData and compares against submitted distributions.
    ///      Reverts if any distribution does not match expected computation.
    /// @param distributions Pre-computed fee distributions from the off-chain engine
    /// @param operationData ABI-encoded raw operations (matches, rollovers, refinances) for validation
    /// @return totalRevenue Total protocol revenue collected in this batch
    function validateAndExecuteFees(
        FeeDistribution[] calldata distributions,
        bytes calldata operationData
    ) external returns (uint256 totalRevenue);

    // ============ Fee Computation (View) ============

    /// @notice Compute fee distribution for a match operation
    /// @dev Used by the off-chain engine to pre-compute distributions before signing
    /// @param asset The lending asset (e.g., USDC)
    /// @param principal The matched principal amount
    /// @param rateBPS The interest rate in basis points
    /// @param matchTimestamp The timestamp when the match occurred
    /// @param maturity The maturity timestamp
    /// @param lender The lender address
    /// @param borrower The borrower address
    /// @return distribution The computed fee distribution
    function computeMatchFees(
        address asset,
        uint256 principal,
        uint256 rateBPS,
        uint256 matchTimestamp,
        uint256 maturity,
        address lender,
        address borrower
    ) external view returns (FeeDistribution memory distribution);

    /// @notice Compute fee distribution for a rollover operation
    /// @dev Rollover fee is a percentage of yield earned during the expired period
    /// @param asset The lending asset
    /// @param yieldEarned The interest earned during the expired period
    /// @param lender The lender address
    /// @return distribution The computed fee distribution
    function computeRolloverFees(
        address asset,
        uint256 yieldEarned,
        address lender
    ) external view returns (FeeDistribution memory distribution);

    /// @notice Compute fee distribution for a refinance operation
    /// @param asset The borrow asset
    /// @param interestAccrued The interest accrued during the expired period
    /// @param borrower The borrower address
    /// @return distribution The computed fee distribution
    function computeRefinanceFees(
        address asset,
        uint256 interestAccrued,
        address borrower
    ) external view returns (FeeDistribution memory distribution);

    // ============ Parameter Reads ============

    /// @notice Get the taker fee in basis points (% of interest)
    function takerFeeBPS() external view returns (uint256);

    /// @notice Get the maker rebate in basis points (% of interest)
    function makerRebateBPS() external view returns (uint256);

    /// @notice Get the rollover fee in basis points (% of yield)
    function rolloverFeeBPS() external view returns (uint256);

    /// @notice Get the flat settlement fee per side (in asset decimals)
    function settlementFeePerSide() external view returns (uint256);

    /// @notice Get the protocol treasury address
    function protocolTreasury() external view returns (address);

    // ============ Events ============

    event FeesExecuted(
        bytes32 indexed operationId,
        uint8 operationType,
        uint256 totalProtocolRevenue
    );

    event FeeParameterUpdated(bytes32 indexed paramId, uint256 oldValue, uint256 newValue);
    event FeeParameterProposed(bytes32 indexed paramId, uint256 newValue, uint256 timelockEnd);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ============ Errors ============

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error ContractPaused();
    error FeeMismatch(bytes32 operationId, uint256 expected, uint256 submitted);
    error InvalidOperationType(uint8 operationType);
    error TakerFeeMustExceedMakerRebate();
    error FeeExceedsMaximum(uint256 fee, uint256 max);
    error TimelockNotExpired();
    error NoPendingUpdate(bytes32 paramId);
    error LenderWouldLoseMoney(uint256 interest, uint256 netFee);
}
