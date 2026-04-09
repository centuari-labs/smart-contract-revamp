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
import {IAssetBehaviorRegistry} from "../interfaces/IAssetBehaviorRegistry.sol";
import {ILiquidationEngine} from "../interfaces/ILiquidationEngine.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICBT} from "../interfaces/ICBT.sol";
import {CentuariBondERC20Factory} from "./centuari/CentuariBondERC20Factory.sol";
import {CentuariBondERC20} from "./centuari/CentuariBondERC20.sol";
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
        // C-01 FIX: Hash actual operation CONTENTS, not just array lengths.
        // Without this, an attacker could swap operation contents while keeping
        // the same array length — the signature would still be valid.
        bytes32 batchDigest = keccak256(abi.encode(
            batch.nonce,
            batch.timestamp,
            keccak256(abi.encode(batch.matches)),
            keccak256(abi.encode(batch.rollovers)),
            keccak256(abi.encode(batch.refinances)),
            keccak256(abi.encode(batch.liquidations)),
            keccak256(abi.encode(batch.returnSettlements)),
            keccak256(abi.encode(batch.graceStarts)),
            keccak256(abi.encode(batch.feeDistributions))
        ));

        bytes32 ethSignedHash = batchDigest.toEthSignedMessageHash();
        address recoveredSigner = ethSignedHash.recover(engineSignature);
        if (recoveredSigner != _authorizedSigner) revert InvalidSignature();

        // P2-2 FIX: Gap-allowing nonce with MAX_NONCE_GAP=10.
        // Old: strict equality (nonce == last+1) — any gap permanently bricks settlement.
        // New: allows gaps up to 10 for engine recovery while preventing unbounded skipping.
        if (batch.nonce <= _lastProcessedNonce || batch.nonce > _lastProcessedNonce + MAX_NONCE_GAP) {
            revert NonceTooLow(_lastProcessedNonce + 1, batch.nonce);
        }

        // STEP 3: Verify timestamp within tolerance (±60 seconds)
        if (batch.timestamp > block.timestamp + TIMESTAMP_TOLERANCE ||
            (block.timestamp > TIMESTAMP_TOLERANCE && batch.timestamp < block.timestamp - TIMESTAMP_TOLERANCE)) {
            revert TimestampDrift(batch.timestamp, block.timestamp);
        }

        // 2H FIX: Enforce maximum batch size to prevent gas DoS
        {
            uint256 totalOps = batch.matches.length + batch.rollovers.length
                + batch.refinances.length + batch.liquidations.length
                + batch.returnSettlements.length + batch.graceStarts.length;
            require(totalOps <= MAX_BATCH_SIZE, "CentuariEndpoint: batch too large");
        }

        // STEP 4-11: Process operations in order (12-step execution)
        // Step 4: Process liquidations first (frees collateral)
        _processLiquidations(batch.liquidations);

        // Step 5: Process returns (credit available balance)
        _processReturns(batch.returnSettlements);

        // Step 6: Process rollovers (burn old CBT, mint new CBT)
        _processRollovers(batch.rollovers);

        // Step 6.5: P1-5: Process collateral top-ups BEFORE refinances
        // Ensures HF is corrected before interest settlement checks it
        _processCollateralTopUps(batch.collateralTopUps);

        // Step 7: Process refinances (close old, open new borrow)
        _processRefinances(batch.refinances);

        // Step 8: Process new matches
        _processMatches(batch.matches);

        // P2-8 FIX: Fee processing wrapped in try/catch. A reverting FeeController should
        // NEVER block settlement batch execution (liquidations, matches, rollovers are more critical).
        if (_feeController != address(0) && batch.feeDistributions.length > 0) {
            try IFeeController(_feeController).validateAndExecuteFees(
                batch.feeDistributions,
                abi.encode(batch.matches, batch.rollovers, batch.refinances)
            ) returns (uint256 totalRevenue) {
                emit FeesProcessed(batch.nonce, totalRevenue);
            } catch {
                emit FeeProcessingFailed(batch.nonce);
            }
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
            // C-04 FIX: Use absolute difference to avoid underflow when expectedCBT is small
            uint256 expectedCBT = _computeExpectedCBT(
                m.principal, m.rateBPS, m.matchTimestamp, m.maturity
            );
            uint256 cbtDiff = m.cbtMintAmount > expectedCBT
                ? m.cbtMintAmount - expectedCBT
                : expectedCBT - m.cbtMintAmount;
            if (cbtDiff > CBT_TOLERANCE) {
                revert CBTMintMismatch(expectedCBT, m.cbtMintAmount);
            }

            // Debit lender's available balance (locked funds already unlocked by engine)
            ledger.debit(m.lender, m.lendAsset, m.principal);

            // Credit borrower's available balance
            ledger.credit(m.borrower, m.lendAsset, m.principal);

            // C-03 FIX: Use typed interface calls instead of low-level .call()
            // Low-level calls can silently succeed with unexpected data, causing lender
            // to lose principal without receiving CBT.
            if (_bondTokenFactory != address(0)) {
                address bondToken = CentuariBondERC20Factory(_bondTokenFactory)
                    .getOrCreate(m.lendAsset, m.maturity);
                CentuariBondERC20(bondToken).mint(m.lender, m.cbtMintAmount);
            }

            // M-07 FIX: Reject dust positions below minBorrowAmount
            if (_assetBehaviorRegistry != address(0)) {
                uint256 minBorrow = IAssetBehaviorRegistry(_assetBehaviorRegistry)
                    .getBehavior(m.lendAsset).minBorrowAmount;
                require(m.principal >= minBorrow, "CentuariEndpoint: below min borrow");
            }

            // Record borrow debt in RiskModule
            if (_riskModule != address(0)) {
                // P0-3 FIX: Convert debt to 18-decimal USD via oracle price.
                // Uses RiskModule.toUSD18() which multiplies by oracle price — correct for
                // non-USD stablecoins (IDRX, XSGD) where 1 token ≠ $1.
                uint256 debtNormalized = IRiskModule(_riskModule).toUSD18(m.lendAsset, m.principal);

                IRiskModule(_riskModule).recordUserDebt(m.borrower, debtNormalized);

                // HIGH-02 FIX: Record debt against each collateral asset using a SPLIT share,
                // not the full amount. The old code recorded the FULL debt against EVERY collateral
                // asset, causing N-times inflation of per-collateral debt ceiling counters.
                // E.g., a $10k borrow with 3 collateral assets recorded $30k total across ceilings.
                //
                // New approach: distribute debt evenly across collateral assets.
                // This matches Aave V3's pattern where debt is tracked per-market, not duplicated.
                uint256 numCollateral = m.borrowerCollateralAssets.length;
                uint256 debtPerCollateral = numCollateral > 0 ? debtNormalized / numCollateral : 0;
                uint256 debtRemainder = numCollateral > 0 ? debtNormalized - (debtPerCollateral * numCollateral) : 0;

                for (uint256 j = 0; j < numCollateral; j++) {
                    // First asset gets the remainder from integer division (rounding favors protocol)
                    uint256 debtShare = debtPerCollateral + (j == 0 ? debtRemainder : 0);

                    IRiskModule(_riskModule).recordDebtAgainstAsset(
                        m.borrowerCollateralAssets[j], debtShare
                    );

                    // M-04 FIX: Enforce per-collateral debt ceiling
                    if (_assetBehaviorRegistry != address(0)) {
                        uint256 ceiling = IAssetBehaviorRegistry(_assetBehaviorRegistry)
                            .getBehavior(m.borrowerCollateralAssets[j]).debtCeiling;
                        if (ceiling > 0) {
                            uint256 totalDebt = IRiskModule(_riskModule)
                                .getTotalDebtAgainstAsset(m.borrowerCollateralAssets[j]);
                            require(totalDebt <= ceiling, "CentuariEndpoint: debt ceiling exceeded");
                        }
                    }
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

            // HIGH-1 FIX: Anchor rate check is now UNCONDITIONAL — Invariant #15.
            // The old `if (anchorRateBPS > 0)` allowed the engine to bypass bounds by submitting 0.
            // A compromised HSM signer could roll positions at arbitrary rates.
            require(r.anchorRateBPS > 0, "CentuariEndpoint: anchor rate required for rollover");
            {
                uint256 rateDiff = r.newRateBPS > r.anchorRateBPS
                    ? r.newRateBPS - r.anchorRateBPS
                    : r.anchorRateBPS - r.newRateBPS;
                if (rateDiff > ANCHOR_RATE_TOLERANCE_BPS) {
                    revert CBTMintMismatch(r.anchorRateBPS, r.newRateBPS);
                }
            }

            // Burn old CBT — MUST succeed or entire batch reverts
            if (r.oldCBT != address(0) && r.burnAmount > 0) {
                ICBT(r.oldCBT).burn(r.lender, r.burnAmount);
            }

            // H-02 FIX: Validate new CBT mint amount within ±1 wei tolerance
            if (r.newCBT != address(0) && r.mintAmount > 0) {
                uint256 expectedMint = _computeExpectedCBT(
                    r.newPrincipal, r.newRateBPS, block.timestamp, r.newMaturity
                );
                uint256 mintDiff = r.mintAmount > expectedMint
                    ? r.mintAmount - expectedMint
                    : expectedMint - r.mintAmount;
                if (mintDiff > CBT_TOLERANCE) {
                    revert CBTMintMismatch(expectedMint, r.mintAmount);
                }

                ICBT(r.newCBT).mint(r.lender, r.mintAmount);
            }

            bytes32 newPositionId = keccak256(abi.encode(r.lender, r.newCBT, r.rolloverCount));
            emit PositionRolled(r.lender, bytes32(0), newPositionId, r.newRateBPS, r.newMaturity);
        }
    }

    function _processRefinances(RefinanceSettlement[] calldata refinances) internal {
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);

        for (uint256 i = 0; i < refinances.length; i++) {
            RefinanceSettlement calldata r = refinances[i];

            // H-04 FIX: Anchor rate check is now UNCONDITIONAL for refinances — Invariant #15.
            // The old `if (anchorRateBPS > 0)` allowed bypassing bounds by submitting 0.
            // Must match the rollover pattern at line 269 for consistency.
            require(r.anchorRateBPS > 0, "CentuariEndpoint: anchor rate required for refinance");
            {
                uint256 refRateDiff = r.newRateBPS > r.anchorRateBPS
                    ? r.newRateBPS - r.anchorRateBPS
                    : r.anchorRateBPS - r.newRateBPS;
                if (refRateDiff > ANCHOR_RATE_TOLERANCE_BPS) {
                    revert CBTMintMismatch(r.anchorRateBPS, r.newRateBPS);
                }
            }

            // Interest settlement based on method
            if (r.interestMethod == 0) {
                // ADD_TO_LOAN: collateral unchanged, debt increases by interest
            } else {
                // DEDUCT_COLLATERAL: sell collateral worth interest amount
                if (r.deductAsset != address(0) && r.deductAmount > 0) {
                    ledger.reduceCollateral(r.borrower, r.deductAsset, r.deductAmount);
                }
            }

            // M-02 FIX: Record the new borrow position's full debt.
            // The refinance replaces old debt with new debt (which includes interest for ADD_TO_LOAN).
            // Adjust by the delta so RiskModule accurately tracks the borrower's true debt.
            // P0 FIX: Normalize debt delta to 18-decimal USD (same scale as usdValueCached).
            if (_riskModule != address(0)) {
                IRiskModule riskModule = IRiskModule(_riskModule);

                // P0-3 FIX: Add grace period penalty interest to debt (§5.15).
                // Uses toUSD18() for real USD conversion via oracle.
                if (r.penaltyInterest > 0) {
                    uint256 penaltyNormalized = riskModule.toUSD18(r.lendAsset, r.penaltyInterest);
                    if (penaltyNormalized > 0) {
                        riskModule.recordUserDebt(r.borrower, penaltyNormalized);
                    }
                }

                // P0-3 + P0-4 FIX: Bidirectional debt tracking.
                // Record increase OR decrease — not just increase.
                if (r.newPrincipal > r.oldDebt) {
                    uint256 debtDelta = riskModule.toUSD18(r.lendAsset, r.newPrincipal - r.oldDebt);
                    riskModule.recordUserDebt(r.borrower, debtDelta);
                } else if (r.oldDebt > r.newPrincipal) {
                    uint256 debtReduction = riskModule.toUSD18(r.lendAsset, r.oldDebt - r.newPrincipal);
                    riskModule.reduceUserDebt(r.borrower, debtReduction);
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

            // H-07 FIX: Debit debt repayment FROM liquidator first.
            // Without this, liquidator receives collateral for free — no payment for debt.
            ledger.debit(l.liquidator, l.debtAsset, l.debtRepaid);

            // Reduce borrower's collateral
            ledger.reduceCollateral(l.borrower, l.collateralAsset, l.collateralSeized);

            // Reduce borrower's debt via RiskModule
            // P0-3 FIX: Convert via oracle price for correct USD value (non-USD stablecoins).
            if (_riskModule != address(0)) {
                uint256 debtRepaidNorm = IRiskModule(_riskModule).toUSD18(l.debtAsset, l.debtRepaid);
                IRiskModule(_riskModule).reduceUserDebt(l.borrower, debtRepaidNorm);
                IRiskModule(_riskModule).reduceDebtAgainstAsset(l.collateralAsset, debtRepaidNorm);
            }

            // Credit seized collateral (including bonus) to liquidator
            ledger.credit(l.liquidator, l.collateralAsset, l.collateralSeized);

            // NH-01 FIX: Do NOT credit debtRepaid to borrower.
            // The liquidator's payment stays in BalanceLedger to back CBT redemptions.
            // Crediting it to the borrower would create value from nothing.
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

    /// @dev P1-5: Process collateral top-ups — move available balance to collateral for HF improvement.
    ///      Runs BEFORE refinances so HF is corrected before interest settlement checks it.
    function _processCollateralTopUps(CollateralTopUp[] calldata topUps) internal {
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);
        for (uint256 i = 0; i < topUps.length; i++) {
            CollateralTopUp calldata t = topUps[i];
            ledger.debit(t.borrower, t.asset, t.amount);
            ledger.addCollateral(t.borrower, t.asset, t.amount, t.sourceChainId);
        }
    }

    /// @dev P1-5 FIX: Delegate grace period storage to LiquidationEngine directly.
    ///      Old: stored in Endpoint's _gracePeriods (dead storage, never read by LiqEngine).
    ///      New: calls LiqEngine.setGracePeriod() — single source of truth for grace periods.
    function _processGraceStarts(GracePeriodStart[] calldata graceStarts) internal {
        for (uint256 i = 0; i < graceStarts.length; i++) {
            GracePeriodStart calldata g = graceStarts[i];

            // Delegate to LiquidationEngine (single source of truth)
            if (_liquidationEngine != address(0)) {
                uint256 gracePeriodHours = g.gracePeriodEnds > block.timestamp
                    ? (g.gracePeriodEnds - block.timestamp) / 1 hours
                    : 6; // default 6 hours
                ILiquidationEngine(_liquidationEngine).setGracePeriod(
                    g.positionId, gracePeriodHours, uint8(uint256(g.reason)), 0
                );
            }

            emit GracePeriodStarted(g.borrower, g.positionId, g.reason, g.gracePeriodEnds);
        }
    }

    // ============ Decimal Helpers ============

    /// @notice Fetch the decimals of any ERC20 token via staticcall
    /// @dev Falls back to 18 if the call fails or returns no data (same pattern as CollateralRegistry).
    ///      Used to normalize raw token amounts to 18-decimal USD for RiskModule HF computation.
    /// @param token The ERC20 token address
    /// @return The token's decimal count (0–18)
    function _getTokenDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (!success || data.length == 0) return 18;
        return abi.decode(data, (uint8));
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

    // ============ Administrative (NH-04 FIX: 48h timelock on all admin setters) ============

    /// @notice NH-04 FIX: Propose changing an admin address. Takes effect after 48h timelock.
    /// @param slot The config slot (e.g., "riskModule", "registry", "factory", "multisig", "oracle", "fees")
    /// @param newAddr The proposed new address
    function proposeAdminAddress(bytes32 slot, address newAddr) external onlyOwner {
        if (newAddr == address(0)) revert ZeroAddress();
        _pendingAdminAddresses[slot] = newAddr;
        _pendingAdminTimestamps[slot] = block.timestamp + SIGNER_UPDATE_TIMELOCK;
        emit AdminChangeProposed(slot, newAddr, block.timestamp + SIGNER_UPDATE_TIMELOCK);
    }

    /// @notice NH-04 FIX: Apply a proposed admin address change after timelock expires.
    /// @param slot The config slot to apply
    function applyAdminAddress(bytes32 slot) external onlyOwner {
        require(_pendingAdminAddresses[slot] != address(0), "CentuariEndpoint: no pending");
        require(block.timestamp >= _pendingAdminTimestamps[slot], "CentuariEndpoint: timelock");

        address newAddr = _pendingAdminAddresses[slot];
        delete _pendingAdminAddresses[slot];
        delete _pendingAdminTimestamps[slot];

        if (slot == "riskModule") _riskModule = newAddr;
        else if (slot == "registry") _assetBehaviorRegistry = newAddr;
        else if (slot == "factory") _bondTokenFactory = newAddr;
        else if (slot == "multisig") _multisig = newAddr;
        else if (slot == "oracle") _rateOracle = newAddr;
        else if (slot == "fees") _feeController = newAddr;
        else revert("CentuariEndpoint: invalid slot");

        emit AdminChangeApplied(slot, newAddr);
    }

    /// @notice Cancel a pending admin address proposal
    function cancelAdminProposal(bytes32 slot) external onlyOwner {
        delete _pendingAdminAddresses[slot];
        delete _pendingAdminTimestamps[slot];
    }

    event AdminChangeProposed(bytes32 indexed slot, address newAddr, uint256 unlockTime);
    event AdminChangeApplied(bytes32 indexed slot, address newAddr);

    // ============ CBT Redemption (C-05 FIX) ============

    /// @notice Redeem matured CBT for underlying tokens
    /// @dev C-05 FIX: CBT is immutable (no proxy), so redemption logic lives here.
    ///      Burns the caller's CBT and transfers underlying from BalanceLedger to the caller.
    ///      BalanceLedger holds all underlying ERC20 tokens from user deposits.
    /// @param cbtAddress The CBT token contract to redeem
    /// @param amount The amount of CBT to redeem (1:1 with underlying at maturity)
    function redeemCBT(address cbtAddress, uint256 amount) external whenNotPaused nonReentrant {
        if (cbtAddress == address(0)) revert ZeroAddress();
        require(amount > 0, "CentuariEndpoint: zero redeem amount");

        CentuariBondERC20 cbt = CentuariBondERC20(cbtAddress);

        // Verify maturity has passed
        require(block.timestamp >= cbt.MATURITY(), "CentuariEndpoint: not yet matured");

        // Verify caller has sufficient CBT balance
        require(cbt.balanceOf(msg.sender) >= amount, "CentuariEndpoint: insufficient CBT");

        // Burn CBT from caller — CentuariEndpoint is the MINTER (via factory)
        // so it can call burn(address, uint256) added in C-06 fix
        cbt.burn(msg.sender, amount);

        // CRIT-3 FIX: Verify BalanceLedger has sufficient underlying before transfer.
        // Without this check, redemptions could drain tokens backing user deposits.
        // If underlying is deployed in YieldRouter, this reverts with a clear error
        // instead of silently consuming other users' funds.
        address underlying = cbt.LOAN_TOKEN();
        uint256 ledgerBalance = IERC20(underlying).balanceOf(_balanceLedger);
        require(ledgerBalance >= amount, "CentuariEndpoint: insufficient redemption liquidity");

        // Transfer underlying from BalanceLedger to caller
        IBalanceLedger(_balanceLedger).transferOut(underlying, msg.sender, amount);

        emit CBTRedeemed(msg.sender, cbtAddress, underlying, amount);
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
