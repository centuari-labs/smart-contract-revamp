// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";

import {IFeeController} from "../interfaces/IFeeController.sol";
import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {ICentuariEndpoint} from "../interfaces/ICentuariEndpoint.sol";
import {FeeControllerStorage} from "./FeeControllerStorage.sol";

/// @title FeeController
/// @notice Contains ALL fee logic for the Centuari protocol
/// @dev CentuariEndpoint delegates fee decisions to this contract.
///      Fee parameters are governance-controlled with 48h timelock.
///      This is the ONLY contract that changes when fee logic evolves.
contract FeeController is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    FeeControllerStorage,
    IFeeController
{
    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @param owner_ The owner address (governance)
    /// @param balanceLedger_ The BalanceLedger contract
    /// @param protocolTreasury_ The protocol treasury address
    /// @param centuariEndpoint_ The CentuariEndpoint contract (only caller for fee execution)
    /// @param takerFeeBPS_ Initial taker fee (BPS of interest, e.g., 500 = 5%)
    /// @param makerRebateBPS_ Initial maker rebate (BPS of interest, e.g., 300 = 3%)
    /// @param rolloverFeeBPS_ Initial rollover fee (BPS of yield, e.g., 50 = 0.5%)
    /// @param settlementFeePerSide_ Initial flat settlement fee per side (asset decimals)
    function initialize(
        address owner_,
        address balanceLedger_,
        address protocolTreasury_,
        address centuariEndpoint_,
        uint256 takerFeeBPS_,
        uint256 makerRebateBPS_,
        uint256 rolloverFeeBPS_,
        uint256 settlementFeePerSide_
    ) external initializer {
        if (owner_ == address(0) || balanceLedger_ == address(0) ||
            protocolTreasury_ == address(0) || centuariEndpoint_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _balanceLedger = balanceLedger_;
        _protocolTreasury = protocolTreasury_;
        _centuariEndpoint = centuariEndpoint_;

        // Validate and set initial parameters
        _validateFeeParams(takerFeeBPS_, makerRebateBPS_, rolloverFeeBPS_, settlementFeePerSide_);
        _takerFeeBPS = takerFeeBPS_;
        _makerRebateBPS = makerRebateBPS_;
        _rolloverFeeBPS = rolloverFeeBPS_;
        _refinanceFeeBPS = rolloverFeeBPS_; // Same as rollover at launch
        _settlementFeePerSide = settlementFeePerSide_;
    }

    // ============ Modifiers ============

    modifier onlyEndpoint() {
        if (msg.sender != _centuariEndpoint) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert ContractPaused();
        _;
    }

    // ============ Core Fee Execution ============

    /// @inheritdoc IFeeController
    function validateAndExecuteFees(
        FeeDistribution[] calldata distributions,
        bytes calldata operationData
    ) external override onlyEndpoint whenNotPaused nonReentrant returns (uint256 totalRevenue) {
        // Decode raw operations for validation
        (
            ICentuariEndpoint.MatchedOrder[] memory matches,
            ICentuariEndpoint.RolloverSettlement[] memory rollovers,
            ICentuariEndpoint.RefinanceSettlement[] memory refinances
        ) = abi.decode(
            operationData,
            (ICentuariEndpoint.MatchedOrder[], ICentuariEndpoint.RolloverSettlement[], ICentuariEndpoint.RefinanceSettlement[])
        );

        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);
        uint256 matchIdx;
        uint256 rolloverIdx;
        uint256 refinanceIdx;

        for (uint256 i = 0; i < distributions.length; i++) {
            FeeDistribution calldata dist = distributions[i];

            // Validate fee amounts against raw operation data
            if (dist.operationType == 0) {
                // MATCH
                if (matchIdx >= matches.length) revert InvalidOperationType(0);
                _validateMatchFees(dist, matches[matchIdx]);
                matchIdx++;
            } else if (dist.operationType == 1) {
                // ROLLOVER
                if (rolloverIdx >= rollovers.length) revert InvalidOperationType(1);
                _validateRolloverFees(dist, rollovers[rolloverIdx]);
                rolloverIdx++;
            } else if (dist.operationType == 2) {
                // REFINANCE
                if (refinanceIdx >= refinances.length) revert InvalidOperationType(2);
                _validateRefinanceFees(dist, refinances[refinanceIdx]);
                refinanceIdx++;
            } else {
                revert InvalidOperationType(dist.operationType);
            }

            // Execute all transfers for this distribution
            for (uint256 j = 0; j < dist.transfers.length; j++) {
                FeeTransfer calldata t = dist.transfers[j];
                if (t.amount == 0) continue;

                if (t.isCredit) {
                    ledger.credit(t.account, t.asset, t.amount);
                } else {
                    ledger.debit(t.account, t.asset, t.amount);
                }
            }

            totalRevenue += dist.totalProtocolRevenue;

            emit FeesExecuted(dist.operationId, dist.operationType, dist.totalProtocolRevenue);
        }
    }

    // ============ Fee Computation (View) ============

    /// @inheritdoc IFeeController
    function computeMatchFees(
        address asset,
        uint256 principal,
        uint256 rateBPS,
        uint256 matchTimestamp,
        uint256 maturity,
        address lender,
        address borrower
    ) external view override returns (FeeDistribution memory distribution) {
        uint256 grossInterest = _computeInterest(principal, rateBPS, matchTimestamp, maturity);

        uint256 takerFee = (grossInterest * _takerFeeBPS) / BPS_PRECISION;
        uint256 makerRebate = (grossInterest * _makerRebateBPS) / BPS_PRECISION;
        uint256 settlementFee = _settlementFeePerSide;

        // Safety: if maker rebate < settlement fee for low-interest matches, waive lender settlement fee
        uint256 lenderSettlementFee = settlementFee;
        if (makerRebate < settlementFee) {
            lenderSettlementFee = 0;
        }

        // Compute net lender credit/debit
        uint256 lenderNetCredit;
        uint256 lenderNetDebit;
        if (makerRebate >= lenderSettlementFee) {
            lenderNetCredit = makerRebate - lenderSettlementFee;
        } else {
            lenderNetDebit = lenderSettlementFee - makerRebate;
        }

        uint256 borrowerTotalDebit = takerFee + settlementFee;
        uint256 protocolRevenue = takerFee - makerRebate + lenderSettlementFee + settlementFee;

        // Build transfers array
        uint256 transferCount = 1; // Always: protocol treasury credit
        if (borrowerTotalDebit > 0) transferCount++;
        if (lenderNetCredit > 0) transferCount++;
        if (lenderNetDebit > 0) transferCount++;

        FeeTransfer[] memory transfers = new FeeTransfer[](transferCount);
        uint256 idx;

        // Borrower debit (taker fee + settlement fee)
        if (borrowerTotalDebit > 0) {
            transfers[idx++] = FeeTransfer({
                account: borrower,
                asset: asset,
                amount: borrowerTotalDebit,
                isCredit: false,
                reason: REASON_TAKER_FEE
            });
        }

        // Lender credit (net of maker rebate - settlement fee)
        if (lenderNetCredit > 0) {
            transfers[idx++] = FeeTransfer({
                account: lender,
                asset: asset,
                amount: lenderNetCredit,
                isCredit: true,
                reason: REASON_MAKER_REBATE
            });
        }

        // Lender debit (if settlement fee > maker rebate — edge case for very low interest)
        if (lenderNetDebit > 0) {
            transfers[idx++] = FeeTransfer({
                account: lender,
                asset: asset,
                amount: lenderNetDebit,
                isCredit: false,
                reason: REASON_SETTLEMENT_FEE
            });
        }

        // Protocol treasury credit
        transfers[idx++] = FeeTransfer({
            account: _protocolTreasury,
            asset: asset,
            amount: protocolRevenue,
            isCredit: true,
            reason: REASON_PROTOCOL_REVENUE
        });

        distribution = FeeDistribution({
            operationId: bytes32(0), // Caller fills this
            operationType: 0, // MATCH
            transfers: transfers,
            totalProtocolRevenue: protocolRevenue
        });
    }

    /// @inheritdoc IFeeController
    function computeRolloverFees(
        address asset,
        uint256 yieldEarned,
        address lender
    ) external view override returns (FeeDistribution memory distribution) {
        uint256 rolloverFee = (yieldEarned * _rolloverFeeBPS) / BPS_PRECISION;

        if (rolloverFee == 0) {
            distribution.operationType = 1;
            distribution.transfers = new FeeTransfer[](0);
            return distribution;
        }

        FeeTransfer[] memory transfers = new FeeTransfer[](2);

        // Debit lender for rollover fee
        transfers[0] = FeeTransfer({
            account: lender,
            asset: asset,
            amount: rolloverFee,
            isCredit: false,
            reason: REASON_ROLLOVER_FEE
        });

        // Credit protocol treasury
        transfers[1] = FeeTransfer({
            account: _protocolTreasury,
            asset: asset,
            amount: rolloverFee,
            isCredit: true,
            reason: REASON_PROTOCOL_REVENUE
        });

        distribution = FeeDistribution({
            operationId: bytes32(0),
            operationType: 1, // ROLLOVER
            transfers: transfers,
            totalProtocolRevenue: rolloverFee
        });
    }

    /// @inheritdoc IFeeController
    function computeRefinanceFees(
        address asset,
        uint256 interestAccrued,
        address borrower
    ) external view override returns (FeeDistribution memory distribution) {
        uint256 refinanceFee = (interestAccrued * _refinanceFeeBPS) / BPS_PRECISION;

        if (refinanceFee == 0) {
            distribution.operationType = 2;
            distribution.transfers = new FeeTransfer[](0);
            return distribution;
        }

        FeeTransfer[] memory transfers = new FeeTransfer[](2);

        // Debit borrower for refinance fee
        transfers[0] = FeeTransfer({
            account: borrower,
            asset: asset,
            amount: refinanceFee,
            isCredit: false,
            reason: REASON_REFINANCE_FEE
        });

        // Credit protocol treasury
        transfers[1] = FeeTransfer({
            account: _protocolTreasury,
            asset: asset,
            amount: refinanceFee,
            isCredit: true,
            reason: REASON_PROTOCOL_REVENUE
        });

        distribution = FeeDistribution({
            operationId: bytes32(0),
            operationType: 2, // REFINANCE
            transfers: transfers,
            totalProtocolRevenue: refinanceFee
        });
    }

    // ============ Internal Validation ============

    function _validateMatchFees(
        FeeDistribution calldata dist,
        ICentuariEndpoint.MatchedOrder memory m
    ) internal view {
        uint256 grossInterest = _computeInterest(m.principal, m.rateBPS, m.matchTimestamp, m.maturity);
        uint256 expectedTakerFee = (grossInterest * _takerFeeBPS) / BPS_PRECISION;
        uint256 expectedMakerRebate = (grossInterest * _makerRebateBPS) / BPS_PRECISION;
        uint256 settlementFee = _settlementFeePerSide;

        // Safety: waive lender settlement fee if rebate < settlement fee
        uint256 lenderSettlementFee = settlementFee;
        if (expectedMakerRebate < settlementFee) {
            lenderSettlementFee = 0;
        }

        uint256 expectedProtocolRevenue = expectedTakerFee - expectedMakerRebate + lenderSettlementFee + settlementFee;

        if (dist.totalProtocolRevenue != expectedProtocolRevenue) {
            revert FeeMismatch(dist.operationId, expectedProtocolRevenue, dist.totalProtocolRevenue);
        }

        // Validate borrower total debit
        uint256 expectedBorrowerDebit = expectedTakerFee + settlementFee;
        _validateTransferAmount(dist.transfers, m.borrower, false, expectedBorrowerDebit, dist.operationId);

        // Validate lender net transfer
        if (expectedMakerRebate >= lenderSettlementFee) {
            uint256 expectedLenderCredit = expectedMakerRebate - lenderSettlementFee;
            if (expectedLenderCredit > 0) {
                _validateTransferAmount(dist.transfers, m.lender, true, expectedLenderCredit, dist.operationId);
            }
        } else {
            uint256 expectedLenderDebit = lenderSettlementFee - expectedMakerRebate;
            if (expectedLenderDebit > 0) {
                _validateTransferAmount(dist.transfers, m.lender, false, expectedLenderDebit, dist.operationId);
            }
        }
    }

    function _validateRolloverFees(
        FeeDistribution calldata dist,
        ICentuariEndpoint.RolloverSettlement memory r
    ) internal view {
        // Yield = mintAmount - burnAmount (compounded interest from the expired period)
        uint256 yieldEarned = r.mintAmount > r.burnAmount ? r.mintAmount - r.burnAmount : 0;
        uint256 expectedFee = (yieldEarned * _rolloverFeeBPS) / BPS_PRECISION;

        if (dist.totalProtocolRevenue != expectedFee) {
            revert FeeMismatch(dist.operationId, expectedFee, dist.totalProtocolRevenue);
        }
    }

    function _validateRefinanceFees(
        FeeDistribution calldata dist,
        ICentuariEndpoint.RefinanceSettlement memory r
    ) internal view {
        uint256 expectedFee = (r.interestAccrued * _refinanceFeeBPS) / BPS_PRECISION;

        if (dist.totalProtocolRevenue != expectedFee) {
            revert FeeMismatch(dist.operationId, expectedFee, dist.totalProtocolRevenue);
        }
    }

    function _validateTransferAmount(
        FeeTransfer[] calldata transfers,
        address account,
        bool isCredit,
        uint256 expectedAmount,
        bytes32 operationId
    ) internal pure {
        for (uint256 i = 0; i < transfers.length; i++) {
            if (transfers[i].account == account && transfers[i].isCredit == isCredit) {
                if (transfers[i].amount != expectedAmount) {
                    revert FeeMismatch(operationId, expectedAmount, transfers[i].amount);
                }
                return;
            }
        }
        // Transfer not found — if expected amount is 0, that's ok
        if (expectedAmount > 0) {
            revert FeeMismatch(operationId, expectedAmount, 0);
        }
    }

    // ============ Interest Computation ============

    /// @notice Compute gross interest using canonical seconds-based formula
    /// @dev Same formula as CentuariEndpoint._computeExpectedCBT minus principal
    function _computeInterest(
        uint256 principal,
        uint256 rateBPS,
        uint256 matchTimestamp,
        uint256 maturity
    ) internal pure returns (uint256) {
        if (maturity <= matchTimestamp) return 0;
        uint256 elapsedSeconds = maturity - matchTimestamp;
        return (principal * rateBPS * elapsedSeconds) / (RATE_PRECISION * SECONDS_PER_YEAR);
    }

    // ============ Governance: Fee Parameter Updates ============

    /// @notice Propose a fee parameter update — starts 48h timelock
    /// @param paramId The parameter identifier (PARAM_TAKER_FEE, etc.)
    /// @param newValue The new parameter value
    function proposeFeeUpdate(bytes32 paramId, uint256 newValue) external onlyOwner {
        _pendingParamValues[paramId] = newValue;
        _paramTimelockEnd[paramId] = block.timestamp + TIMELOCK_DURATION;

        emit FeeParameterProposed(paramId, newValue, block.timestamp + TIMELOCK_DURATION);
    }

    /// @notice Apply a pending fee parameter update after timelock expires
    /// @param paramId The parameter identifier
    function applyFeeUpdate(bytes32 paramId) external onlyOwner {
        if (_paramTimelockEnd[paramId] == 0) revert NoPendingUpdate(paramId);
        if (block.timestamp < _paramTimelockEnd[paramId]) revert TimelockNotExpired();

        uint256 newValue = _pendingParamValues[paramId];
        uint256 oldValue;

        if (paramId == PARAM_TAKER_FEE) {
            oldValue = _takerFeeBPS;
            if (newValue > MAX_TAKER_FEE_BPS) revert FeeExceedsMaximum(newValue, MAX_TAKER_FEE_BPS);
            if (newValue <= _makerRebateBPS) revert TakerFeeMustExceedMakerRebate();
            _takerFeeBPS = newValue;
        } else if (paramId == PARAM_MAKER_REBATE) {
            oldValue = _makerRebateBPS;
            if (newValue > MAX_MAKER_REBATE_BPS) revert FeeExceedsMaximum(newValue, MAX_MAKER_REBATE_BPS);
            if (_takerFeeBPS <= newValue) revert TakerFeeMustExceedMakerRebate();
            _makerRebateBPS = newValue;
        } else if (paramId == PARAM_ROLLOVER_FEE) {
            oldValue = _rolloverFeeBPS;
            if (newValue > MAX_ROLLOVER_FEE_BPS) revert FeeExceedsMaximum(newValue, MAX_ROLLOVER_FEE_BPS);
            _rolloverFeeBPS = newValue;
        } else if (paramId == PARAM_REFINANCE_FEE) {
            oldValue = _refinanceFeeBPS;
            if (newValue > MAX_ROLLOVER_FEE_BPS) revert FeeExceedsMaximum(newValue, MAX_ROLLOVER_FEE_BPS);
            _refinanceFeeBPS = newValue;
        } else if (paramId == PARAM_SETTLEMENT_FEE) {
            oldValue = _settlementFeePerSide;
            if (newValue > MAX_SETTLEMENT_FEE) revert FeeExceedsMaximum(newValue, MAX_SETTLEMENT_FEE);
            _settlementFeePerSide = newValue;
        } else {
            revert NoPendingUpdate(paramId);
        }

        // Clear pending state
        delete _pendingParamValues[paramId];
        delete _paramTimelockEnd[paramId];

        emit FeeParameterUpdated(paramId, oldValue, newValue);
    }

    // ============ Administrative ============

    // ============ Admin Address Changes (H-05 FIX: 48h timelock) ============

    /// @notice Propose a new admin address (treasury, endpoint, or ledger)
    function proposeAdminAddress(bytes32 adminId, address newAddress) external onlyOwner {
        if (newAddress == address(0)) revert ZeroAddress();
        _pendingAdminAddresses[adminId] = newAddress;
        _pendingAdminTimelockEnd[adminId] = block.timestamp + TIMELOCK_DURATION;
    }

    /// @notice Apply a pending admin address change after timelock expires
    function applyAdminAddress(bytes32 adminId) external onlyOwner {
        if (_pendingAdminTimelockEnd[adminId] == 0) revert NoPendingUpdate(adminId);
        if (block.timestamp < _pendingAdminTimelockEnd[adminId]) revert TimelockNotExpired();

        address newAddress = _pendingAdminAddresses[adminId];

        if (adminId == ADMIN_TREASURY) {
            address old = _protocolTreasury;
            _protocolTreasury = newAddress;
            emit ProtocolTreasuryUpdated(old, newAddress);
        } else if (adminId == ADMIN_ENDPOINT) {
            _centuariEndpoint = newAddress;
        } else if (adminId == ADMIN_LEDGER) {
            _balanceLedger = newAddress;
        } else {
            revert NoPendingUpdate(adminId);
        }

        delete _pendingAdminAddresses[adminId];
        delete _pendingAdminTimelockEnd[adminId];
    }

    /// @notice Cancel a pending admin address change
    function cancelAdminAddress(bytes32 adminId) external onlyOwner {
        delete _pendingAdminAddresses[adminId];
        delete _pendingAdminTimelockEnd[adminId];
    }

    function pause() external onlyOwner {
        _paused = true;
    }

    function unpause() external onlyOwner {
        _paused = false;
    }

    // ============ View Functions ============

    /// @inheritdoc IFeeController
    function takerFeeBPS() external view override returns (uint256) { return _takerFeeBPS; }

    /// @inheritdoc IFeeController
    function makerRebateBPS() external view override returns (uint256) { return _makerRebateBPS; }

    /// @inheritdoc IFeeController
    function rolloverFeeBPS() external view override returns (uint256) { return _rolloverFeeBPS; }

    /// @inheritdoc IFeeController
    function settlementFeePerSide() external view override returns (uint256) { return _settlementFeePerSide; }

    /// @inheritdoc IFeeController
    function protocolTreasury() external view override returns (address) { return _protocolTreasury; }

    function refinanceFeeBPS() external view returns (uint256) { return _refinanceFeeBPS; }

    function balanceLedger() external view returns (address) { return _balanceLedger; }

    function centuariEndpoint() external view returns (address) { return _centuariEndpoint; }

    function paused() external view returns (bool) { return _paused; }

    // ============ Internal Helpers ============

    function _validateFeeParams(
        uint256 takerFee_,
        uint256 makerRebate_,
        uint256 rolloverFee_,
        uint256 settlementFee_
    ) internal pure {
        if (takerFee_ > MAX_TAKER_FEE_BPS) revert FeeExceedsMaximum(takerFee_, MAX_TAKER_FEE_BPS);
        if (makerRebate_ > MAX_MAKER_REBATE_BPS) revert FeeExceedsMaximum(makerRebate_, MAX_MAKER_REBATE_BPS);
        if (takerFee_ <= makerRebate_) revert TakerFeeMustExceedMakerRebate();
        if (rolloverFee_ > MAX_ROLLOVER_FEE_BPS) revert FeeExceedsMaximum(rolloverFee_, MAX_ROLLOVER_FEE_BPS);
        if (settlementFee_ > MAX_SETTLEMENT_FEE) revert FeeExceedsMaximum(settlementFee_, MAX_SETTLEMENT_FEE);
    }
}
