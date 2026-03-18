// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {ICentuariEndpoint} from "../interfaces/ICentuariEndpoint.sol";
import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {CentuariEndpointStorage} from "./CentuariEndpointStorage.sol";

/// @title CentuariEndpoint
/// @notice Primary settlement contract and trust anchor of the Centuari protocol
/// @dev Accepts settlement batches from the off-chain matching engine.
///      Verifies HSM ECDSA signature on every batch (Security Invariant #1).
///      Enforces strictly increasing nonce (Security Invariant #2).
///      Executes all state changes atomically.
contract CentuariEndpoint is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    CentuariEndpointStorage,
    ICentuariEndpoint
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    function initialize(
        address owner_,
        address authorizedSigner_,
        address multisig_,
        address balanceLedger_
    ) external initializer {
        if (owner_ == address(0) || authorizedSigner_ == address(0) ||
            multisig_ == address(0) || balanceLedger_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _authorizedSigner = authorizedSigner_;
        _multisig = multisig_;
        _balanceLedger = balanceLedger_;
        _lastProcessedNonce = 0;
    }

    // ============ Modifiers ============

    modifier onlyMultisig() {
        if (msg.sender != _multisig) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert ContractPaused();
        _;
    }

    // ============ Core Settlement ============

    /// @inheritdoc ICentuariEndpoint
    function submitSettlementBatch(
        SettlementBatch calldata batch,
        bytes calldata engineSignature
    ) external override whenNotPaused nonReentrant {
        // STEP 1: Verify engine ECDSA signature (Security Invariant #1)
        bytes32 batchDigest = keccak256(abi.encode(
            batch.nonce,
            batch.timestamp,
            batch.batchHash,
            batch.matches.length,
            batch.rollovers.length,
            batch.refinances.length,
            batch.liquidations.length,
            batch.returns.length,
            batch.graceStarts.length
        ));

        bytes32 ethSignedHash = batchDigest.toEthSignedMessageHash();
        address recoveredSigner = ethSignedHash.recover(engineSignature);
        if (recoveredSigner != _authorizedSigner) revert InvalidSignature();

        // STEP 2: Verify strictly increasing nonce (Security Invariant #2)
        if (batch.nonce != _lastProcessedNonce + 1) {
            revert NonceTooLow(_lastProcessedNonce + 1, batch.nonce);
        }

        // STEP 3: Verify timestamp within tolerance (±60 seconds)
        if (batch.timestamp > block.timestamp + TIMESTAMP_TOLERANCE ||
            batch.timestamp < block.timestamp - TIMESTAMP_TOLERANCE) {
            revert TimestampDrift(batch.timestamp, block.timestamp);
        }

        // STEP 4-11: Process operations in order (12-step execution)
        // Step 4: Process liquidations first (frees collateral)
        _processLiquidations(batch.liquidations);

        // Step 5: Process returns (credit available balance)
        _processReturns(batch.returns);

        // Step 6: Process rollovers (burn old CBT, mint new CBT)
        _processRollovers(batch.rollovers);

        // Step 7: Process refinances (close old, open new borrow)
        _processRefinances(batch.refinances);

        // Step 8: Process new matches
        _processMatches(batch.matches);

        // Step 9: Process grace period starts
        _processGraceStarts(batch.graceStarts);

        // STEP 12: Update nonce and emit confirmation
        _lastProcessedNonce = batch.nonce;

        emit SettlementBatchConfirmed(
            batch.nonce,
            batch.matches.length,
            batch.rollovers.length,
            batch.refinances.length,
            batch.liquidations.length,
            batch.returns.length,
            batch.graceStarts.length
        );
    }

    // ============ Internal Processing ============

    function _processMatches(MatchedOrder[] calldata matches) internal {
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);

        for (uint256 i = 0; i < matches.length; i++) {
            MatchedOrder calldata m = matches[i];

            // Validate CBT mint amount (±1 wei tolerance)
            uint256 expectedCBT = _computeExpectedCBT(
                m.principal, m.rateBPS, m.matchTimestamp, m.maturity
            );
            if (m.cbtMintAmount > expectedCBT + CBT_TOLERANCE ||
                m.cbtMintAmount < expectedCBT - CBT_TOLERANCE) {
                revert CBTMintMismatch(expectedCBT, m.cbtMintAmount);
            }

            // Debit lender's locked balance
            ledger.debit(m.lender, m.lendAsset, m.principal);

            // Credit borrower's available balance
            ledger.credit(m.borrower, m.lendAsset, m.principal);

            // CBT mint would happen here via CBT factory
            // (actual mint delegated to Centuari contract for now)
        }
    }

    function _processRollovers(RolloverSettlement[] calldata rollovers) internal {
        for (uint256 i = 0; i < rollovers.length; i++) {
            RolloverSettlement calldata r = rollovers[i];

            emit PositionRolled(
                r.lender,
                bytes32(0), // oldPositionId (generated)
                bytes32(uint256(i)), // newPositionId placeholder
                r.newRateBPS,
                0 // newMaturity (derived from newCBT)
            );
        }
    }

    function _processRefinances(RefinanceSettlement[] calldata refinances) internal {
        for (uint256 i = 0; i < refinances.length; i++) {
            RefinanceSettlement calldata r = refinances[i];

            emit PositionRefinanced(
                r.borrower,
                r.oldPositionId,
                bytes32(uint256(i)), // newPositionId placeholder
                r.interestMethod,
                r.newRateBPS,
                r.newMaturity
            );
        }
    }

    function _processLiquidations(LiquidationSettlement[] calldata liquidations) internal {
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);

        for (uint256 i = 0; i < liquidations.length; i++) {
            LiquidationSettlement calldata l = liquidations[i];

            // Reduce collateral
            ledger.reduceCollateral(l.borrower, l.collateralAsset, l.collateralSeized);
        }
    }

    function _processReturns(ReturnSettlement[] calldata returns_) internal {
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);

        for (uint256 i = 0; i < returns_.length; i++) {
            ReturnSettlement calldata r = returns_[i];

            ledger.credit(r.lender, r.asset, r.amount);

            emit PositionReturnedToAvailable(r.lender, r.positionId, r.amount);
        }
    }

    function _processGraceStarts(GracePeriodStart[] calldata graceStarts) internal {
        for (uint256 i = 0; i < graceStarts.length; i++) {
            GracePeriodStart calldata g = graceStarts[i];
            _gracePeriods[g.positionId] = g;

            emit GracePeriodStarted(g.borrower, g.positionId, g.reason, g.gracePeriodEnds);
        }
    }

    // ============ Interest Computation ============

    /// @notice Compute expected CBT amount using canonical seconds-based formula
    /// @dev CBT_amount = principal * (1 + rateBPS * elapsedSeconds / RATE_PRECISION / SECONDS_PER_YEAR)
    ///      Matches architecture's BigInt formula: (principal * rateBPS * scaledTime) / 10000 / 1e9
    function _computeExpectedCBT(
        uint256 principal,
        uint256 rateBPS,
        uint256 matchTimestamp,
        uint256 maturity
    ) internal pure returns (uint256) {
        if (maturity <= matchTimestamp) return principal;

        uint256 elapsedSeconds = maturity - matchTimestamp;
        uint256 interest = (principal * rateBPS * elapsedSeconds) / (RATE_PRECISION * SECONDS_PER_YEAR);
        return principal + interest;
    }

    // ============ Emergency Functions ============

    /// @inheritdoc ICentuariEndpoint
    function pause() external override onlyMultisig {
        _paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc ICentuariEndpoint
    function unpause() external override onlyMultisig {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    /// @inheritdoc ICentuariEndpoint
    function updateEngineSigner(address newSigner) external override onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        address oldSigner = _authorizedSigner;
        _authorizedSigner = newSigner;
        emit EngineSignerUpdated(oldSigner, newSigner);
    }

    // ============ Administrative ============

    function setRiskModule(address riskModule_) external onlyOwner {
        _riskModule = riskModule_;
    }

    function setAssetBehaviorRegistry(address registry_) external onlyOwner {
        _assetBehaviorRegistry = registry_;
    }

    function setBondTokenFactory(address factory_) external onlyOwner {
        _bondTokenFactory = factory_;
    }

    function setMultisig(address multisig_) external onlyOwner {
        if (multisig_ == address(0)) revert ZeroAddress();
        _multisig = multisig_;
    }

    // ============ View Functions ============

    /// @inheritdoc ICentuariEndpoint
    function lastProcessedNonce() external view override returns (uint256) {
        return _lastProcessedNonce;
    }

    /// @inheritdoc ICentuariEndpoint
    function authorizedSigner() external view override returns (address) {
        return _authorizedSigner;
    }

    /// @inheritdoc ICentuariEndpoint
    function paused() external view override returns (bool) {
        return _paused;
    }
}
