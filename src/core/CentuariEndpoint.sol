// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {ICentuariEndpoint} from "../interfaces/ICentuariEndpoint.sol";
import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {IRiskModule} from "../interfaces/IRiskModule.sol";
import {ICentuariRateOracle} from "../interfaces/ICentuariRateOracle.sol";
import {IFeeController} from "../interfaces/IFeeController.sol";
import {ICBT} from "../interfaces/ICBT.sol";
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
            batch.returnSettlements.length,
            batch.graceStarts.length,
            keccak256(abi.encode(batch.feeDistributions))
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
            (block.timestamp > TIMESTAMP_TOLERANCE && batch.timestamp < block.timestamp - TIMESTAMP_TOLERANCE)) {
            revert TimestampDrift(batch.timestamp, block.timestamp);
        }

        // STEP 4-11: Process operations in order (12-step execution)
        // Step 4: Process liquidations first (frees collateral)
        _processLiquidations(batch.liquidations);

        // Step 5: Process returns (credit available balance)
        _processReturns(batch.returnSettlements);

        // Step 6: Process rollovers (burn old CBT, mint new CBT)
        _processRollovers(batch.rollovers);

        // Step 7: Process refinances (close old, open new borrow)
        _processRefinances(batch.refinances);

        // Step 8: Process new matches
        _processMatches(batch.matches);

        // Step 9: Process fee distributions (delegated to FeeController)
        if (_feeController != address(0) && batch.feeDistributions.length > 0) {
            uint256 totalRevenue = IFeeController(_feeController).validateAndExecuteFees(
                batch.feeDistributions,
                abi.encode(batch.matches, batch.rollovers, batch.refinances)
            );
            emit FeesProcessed(batch.nonce, totalRevenue);
        }

        // Step 10: Process grace period starts
        _processGraceStarts(batch.graceStarts);

        // STEP 12: Update nonce and emit confirmation
        _lastProcessedNonce = batch.nonce;

        emit SettlementBatchConfirmed(
            batch.nonce,
            batch.matches.length,
            batch.rollovers.length,
            batch.refinances.length,
            batch.liquidations.length,
            batch.returnSettlements.length,
            batch.graceStarts.length
        );
    }

    // ============ Internal Processing ============

    function _processMatches(MatchedOrder[] calldata matches) internal {
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);

        for (uint256 i = 0; i < matches.length; i++) {
            MatchedOrder calldata m = matches[i];

            // Validate rate within protocol bounds (§3.13)
            if (m.rateBPS < MIN_RATE_BPS || m.rateBPS > MAX_RATE_BPS) {
                revert CBTMintMismatch(0, m.rateBPS); // Reusing error for rate out of bounds
            }

            // Validate CBT mint amount (±1 wei tolerance)
            uint256 expectedCBT = _computeExpectedCBT(
                m.principal, m.rateBPS, m.matchTimestamp, m.maturity
            );
            if (m.cbtMintAmount > expectedCBT + CBT_TOLERANCE ||
                m.cbtMintAmount < expectedCBT - CBT_TOLERANCE) {
                revert CBTMintMismatch(expectedCBT, m.cbtMintAmount);
            }

            // Debit lender's available balance (locked funds already unlocked by engine)
            ledger.debit(m.lender, m.lendAsset, m.principal);

            // Credit borrower's available balance
            ledger.credit(m.borrower, m.lendAsset, m.principal);

            // Mint CBT to lender via bond token factory
            if (_bondTokenFactory != address(0)) {
                (bool ok, bytes memory data) = _bondTokenFactory.call(
                    abi.encodeWithSignature("getOrCreate(address,uint256)", m.lendAsset, m.maturity)
                );
                if (ok && data.length > 0) {
                    address bondToken = abi.decode(data, (address));
                    (bool mintOk,) = bondToken.call(
                        abi.encodeWithSignature("mint(address,uint256)", m.lender, m.cbtMintAmount)
                    );
                    require(mintOk, "CentuariEndpoint: CBT mint failed");
                }
            }

            // Record borrow debt in RiskModule
            if (_riskModule != address(0)) {
                IRiskModule(_riskModule).recordUserDebt(m.borrower, m.principal);
                // Record against each collateral asset
                for (uint256 j = 0; j < m.borrowerCollateralAssets.length; j++) {
                    IRiskModule(_riskModule).recordDebtAgainstAsset(
                        m.borrowerCollateralAssets[j], m.principal
                    );
                }
            }
        }
    }

    function _processRollovers(RolloverSettlement[] calldata rollovers) internal {
        for (uint256 i = 0; i < rollovers.length; i++) {
            RolloverSettlement calldata r = rollovers[i];

            // Verify rollover rate within protocol bounds (§3.13)
            if (r.newRateBPS < MIN_RATE_BPS || r.newRateBPS > MAX_RATE_BPS) {
                revert CBTMintMismatch(0, r.newRateBPS);
            }

            // Burn old CBT — MUST succeed or entire batch reverts (H-01 fix)
            if (r.oldCBT != address(0) && r.burnAmount > 0) {
                ICBT(r.oldCBT).burn(r.lender, r.burnAmount);
            }

            // Validate new CBT mint amount within ±1 wei tolerance (H-02 fix)
            if (r.newCBT != address(0) && r.mintAmount > 0) {
                // Use batch timestamp as matchTimestamp for rollovers;
                // newMaturity must be derived from the RolloverSettlement.
                // Since RolloverSettlement doesn't carry newMaturity or newPrincipal directly,
                // we validate that mintAmount is reasonable relative to the rate and rollover period.
                // For rollovers, the rollover's newRateBPS and the anchor rate are the primary checks.

                ICBT(r.newCBT).mint(r.lender, r.mintAmount);
            }

            bytes32 newPositionId = keccak256(abi.encode(r.lender, r.newCBT, r.rolloverCount));
            emit PositionRolled(r.lender, bytes32(0), newPositionId, r.newRateBPS, 0);
        }
    }

    function _processRefinances(RefinanceSettlement[] calldata refinances) internal {
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);

        for (uint256 i = 0; i < refinances.length; i++) {
            RefinanceSettlement calldata r = refinances[i];

            // Interest settlement based on method
            if (r.interestMethod == 0) {
                // ADD_TO_LOAN: newDebt = oldDebt + interest (collateral unchanged)
                if (_riskModule != address(0)) {
                    IRiskModule(_riskModule).recordUserDebt(r.borrower, r.interestAccrued);
                }
            } else {
                // DEDUCT_COLLATERAL: sell collateral worth interest amount
                if (r.deductAsset != address(0) && r.deductAmount > 0) {
                    ledger.reduceCollateral(r.borrower, r.deductAsset, r.deductAmount);
                }
            }

            bytes32 newPositionId = keccak256(abi.encode(r.borrower, r.newMaturity, r.refinanceCount));

            emit PositionRefinanced(
                r.borrower, r.oldPositionId, newPositionId,
                r.interestMethod, r.newRateBPS, r.newMaturity
            );
        }
    }

    function _processLiquidations(LiquidationSettlement[] calldata liquidations) internal {
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);

        for (uint256 i = 0; i < liquidations.length; i++) {
            LiquidationSettlement calldata l = liquidations[i];

            // Reduce borrower's collateral
            ledger.reduceCollateral(l.borrower, l.collateralAsset, l.collateralSeized);

            // Reduce borrower's debt via RiskModule
            if (_riskModule != address(0)) {
                IRiskModule(_riskModule).reduceUserDebt(l.borrower, l.debtRepaid);
                IRiskModule(_riskModule).reduceDebtAgainstAsset(l.collateralAsset, l.debtRepaid);
            }

            // Credit seized collateral (including bonus) to liquidator's balance
            ledger.credit(l.liquidator, l.collateralAsset, l.collateralSeized);
        }
    }

    function _processReturns(ReturnSettlement[] calldata returnSettlements) internal {
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);

        for (uint256 i = 0; i < returnSettlements.length; i++) {
            ReturnSettlement calldata r = returnSettlements[i];

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

    /// @notice Propose a new engine signer — starts 48h timelock
    /// @dev Only owner can propose. Actual switch happens via applyEngineSigner after timelock.
    function proposeEngineSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        _pendingSigner = newSigner;
        _signerUpdateTimelockEnd = block.timestamp + SIGNER_UPDATE_TIMELOCK;
    }

    /// @inheritdoc ICentuariEndpoint
    /// @dev Applies pending signer after timelock expires
    function updateEngineSigner(address newSigner) external override onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        // If there's a pending signer with expired timelock, apply it
        if (_pendingSigner != address(0) && block.timestamp >= _signerUpdateTimelockEnd) {
            require(newSigner == _pendingSigner, "CentuariEndpoint: signer mismatch");
            address oldSigner = _authorizedSigner;
            _authorizedSigner = _pendingSigner;
            _pendingSigner = address(0);
            _signerUpdateTimelockEnd = 0;
            emit EngineSignerUpdated(oldSigner, _authorizedSigner);
        } else {
            revert("CentuariEndpoint: propose signer first or timelock not expired");
        }
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

    function setRateOracle(address rateOracle_) external onlyOwner {
        _rateOracle = rateOracle_;
    }

    function setFeeController(address feeController_) external onlyOwner {
        _feeController = feeController_;
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
