// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFeeController} from "./IFeeController.sol";

/// @title ICentuariEndpoint
/// @notice Primary settlement contract and trust anchor of the Centuari protocol
/// @dev Accepts settlement batches from the off-chain matching engine.
///      Verifies HSM signature on every batch. Executes all state changes atomically.
interface ICentuariEndpoint {
    // ============ Structs ============

    /// @notice Complete settlement batch submitted by the engine
    struct SettlementBatch {
        MatchedOrder[] matches;
        RolloverSettlement[] rollovers;
        RefinanceSettlement[] refinances;
        LiquidationSettlement[] liquidations;
        ReturnSettlement[] returnSettlements;
        GracePeriodStart[] graceStarts;
        IFeeController.FeeDistribution[] feeDistributions;
        uint256 nonce;
        uint256 timestamp;
        bytes32 batchHash;
    }

    /// @notice A matched lend/borrow order pair
    struct MatchedOrder {
        address lender;
        address borrower;
        address lendAsset;
        uint256 principal;
        uint256 rateBPS;
        uint256 maturity;
        uint256 cbtMintAmount;
        uint256 matchTimestamp;
        address[] borrowerCollateralAssets;
        bytes32 lendOrderId;
        bytes32 borrowOrderId;
    }

    /// @notice A lend position being rolled over at maturity
    struct RolloverSettlement {
        address lender;
        address oldCBT;
        uint256 burnAmount;
        address newCBT;
        uint256 mintAmount;
        uint256 newRateBPS;
        uint256 anchorRateBPS;
        uint8 rolloverCount;
        uint256 newMaturity;    // H-02 FIX: needed for CBT mint validation
        uint256 newPrincipal;   // H-02 FIX: compounded principal for validation
    }

    /// @notice A borrow position being refinanced at maturity
    struct RefinanceSettlement {
        address borrower;
        bytes32 oldPositionId;
        uint256 oldDebt;
        uint256 interestAccrued;
        uint8 interestMethod; // 0 = ADD_TO_LOAN, 1 = DEDUCT_COLLATERAL
        address deductAsset;
        uint256 deductAmount;
        uint256 newPrincipal;
        uint256 newRateBPS;
        uint256 newMaturity;
        uint8 refinanceCount;
        address lendAsset;    // P0 FIX: debt asset for 18-dec normalization in RiskModule
        uint256 anchorRateBPS; // MED-1 FIX: anchor rate for bounds check (same as rollovers)
        uint256 penaltyInterest; // P0-3 FIX: grace period penalty (§5.15), computed off-chain as 2x VWAP
    }

    /// @notice A liquidation being executed
    struct LiquidationSettlement {
        address borrower;
        bytes32 positionId;
        address liquidator;
        address collateralAsset;
        uint256 collateralSeized;
        uint256 debtRepaid;
        uint256 bonusBPS;
        address debtAsset;      // H-07 FIX: asset liquidator pays to cover debt
    }

    /// @notice Principal + interest returned to lender (failed rollover)
    struct ReturnSettlement {
        address lender;
        bytes32 positionId;
        address asset;
        uint256 amount;
    }

    /// @notice A borrow position entering grace period
    struct GracePeriodStart {
        address borrower;
        bytes32 positionId;
        bytes32 reason;
        uint256 gracePeriodEnds;
    }

    // ============ Core Settlement ============

    /// @notice Submit a settlement batch from the matching engine
    /// @dev Verifies: (1) ECDSA signature, (2) nonce, (3) timestamp, (4) CBT amounts, (5) balances
    ///      Executes atomically — entire batch succeeds or entire batch reverts.
    /// @param batch The settlement batch data
    /// @param engineSignature The ECDSA signature from the authorized engine signer
    function submitSettlementBatch(
        SettlementBatch calldata batch,
        bytes calldata engineSignature
    ) external;

    // ============ Emergency ============

    /// @notice Pause all settlement — callable by multisig only
    function pause() external;

    /// @notice Unpause settlement — callable by multisig only
    function unpause() external;

    /// @notice Update the authorized engine signer — requires multisig + timelock
    /// @param newSigner The new engine signer address
    function updateEngineSigner(address newSigner) external;

    // ============ View Functions ============

    /// @notice Get the last processed settlement batch nonce
    function lastProcessedNonce() external view returns (uint256);

    /// @notice Get the authorized engine signer address
    function authorizedSigner() external view returns (address);

    /// @notice Check if the contract is paused
    function paused() external view returns (bool);

    // ============ Events ============

    event SettlementBatchConfirmed(
        uint256 indexed nonce,
        uint256 matchCount,
        uint256 rolloverCount,
        uint256 refinanceCount,
        uint256 liquidationCount,
        uint256 returnCount,
        uint256 graceStartCount
    );

    event PositionRolled(
        address indexed lender,
        bytes32 indexed oldPositionId,
        bytes32 indexed newPositionId,
        uint256 newRate,
        uint256 newMaturity
    );

    event PositionRefinanced(
        address indexed borrower,
        bytes32 indexed oldPositionId,
        bytes32 indexed newPositionId,
        uint256 interestMethod,
        uint256 newRate,
        uint256 newMaturity
    );

    event PositionReturnedToAvailable(
        address indexed lender,
        bytes32 indexed positionId,
        uint256 amount
    );

    event GracePeriodStarted(
        address indexed borrower,
        bytes32 indexed positionId,
        bytes32 reason,
        uint256 gracePeriodEnds
    );

    event FeesProcessed(uint256 indexed nonce, uint256 totalProtocolRevenue);
    event CBTRedeemed(address indexed redeemer, address indexed cbtAddress, address underlying, uint256 amount);
    event EngineSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    // ============ Errors ============

    error Unauthorized();
    error InvalidSignature();
    error NonceTooLow(uint256 expected, uint256 received);
    error TimestampDrift(uint256 batchTimestamp, uint256 blockTimestamp);
    error CBTMintMismatch(uint256 expected, uint256 received);
    error InsufficientBalance(address user, address asset);
    error ContractPaused();
    error ZeroAddress();
    error BatchEmpty();
}
