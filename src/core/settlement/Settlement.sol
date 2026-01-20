// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../../utils/ReentrancyGuardUpgradeable.sol";

import {ISettlement} from "../../interfaces/ISettlement.sol";
import {ICentuari} from "../../interfaces/ICentuari.sol";
import {SettlementStorage} from "./SettlementStorage.sol";

/// @title Settlement
/// @notice Processes batch settlements from the matching engine
/// @dev This contract validates matches, prevents double-settlement, and calls Centuari for position updates.
///      It is designed to be deployed behind an ERC1967 proxy for upgradeability.
contract Settlement is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    SettlementStorage,
    ISettlement
{
    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initialize the Settlement contract
    /// @dev Can only be called once. Sets owner, operator, and Centuari address.
    /// @param owner_ The owner address (can update operator and Centuari)
    /// @param operator_ The settlement engine operator address
    /// @param centuari_ The Centuari contract address
    function initialize(
        address owner_,
        address operator_,
        address centuari_
    ) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();
        if (centuari_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _operator = operator_;
        _centuari = centuari_;
        _paused = false;

        emit OperatorUpdated(address(0), operator_);
        emit CentuariUpdated(address(0), centuari_);
    }

    // ============ Modifiers ============

    /// @notice Restricts function access to the operator
    modifier onlyOperator() {
        if (msg.sender != _operator) revert Unauthorized();
        _;
    }

    /// @notice Ensures the contract is not paused
    modifier whenNotPaused() {
        if (_paused) revert ContractPaused();
        _;
    }

    // ============ Core Settlement Functions ============

    /// @inheritdoc ISettlement
    function settleMatches(MatchData[] calldata matches)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        uint256 matchCount = matches.length;
        if (matchCount == 0) revert EmptyBatch();

        uint256 totalVolume;

        // Cache Centuari address to save gas on repeated reads
        address centuariAddr = _centuari;

        for (uint256 i; i < matchCount; ) {
            MatchData calldata matchData = matches[i];

            // Process the match
            _processMatch(matchData, centuariAddr);

            // Accumulate total volume
            totalVolume += matchData.matchedAmount;

            unchecked {
                ++i;
            }
        }

        emit BatchSettlementCompleted(matchCount, totalVolume);
    }

    /// @inheritdoc ISettlement
    function settleMatch(MatchData calldata matchData)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        _processMatch(matchData, _centuari);

        emit BatchSettlementCompleted(1, matchData.matchedAmount);
    }

    // ============ Internal Functions ============

    /// @notice Process a single match - validate, mark as settled, and call Centuari
    /// @param matchData The match data to process
    /// @param centuariAddr The cached Centuari contract address
    function _processMatch(
        MatchData calldata matchData,
        address centuariAddr
    ) internal {
        // Validate match data
        _validateMatchData(matchData);

        // Check for double-settlement using matchId from settlement engine
        bytes32 matchId = matchData.matchId;
        if (_settledMatches[matchId]) revert AlreadySettled(matchId);

        // Mark as settled before external call (checks-effects-interactions)
        _settledMatches[matchId] = true;

        // Call Centuari to handle positions and token transfers
        ICentuari(centuariAddr).settleMatch(
            matchData.lender,
            matchData.borrower,
            matchData.loanToken,
            matchData.matchedAmount,
            matchData.rate,
            matchData.maturity,
            matchData.borrowerIsTaker,
            matchData.lenderSettlementFee,
            matchData.borrowerSettlementFee,
            matchData.makerFeeAmount,
            matchData.takerFeeAmount
        );

        // Emit individual match event
        emit MatchSettled(
            matchData.matchId,
            matchData.lendOrderId,
            matchData.borrowOrderId,
            matchData.lender,
            matchData.borrower,
            matchData.loanToken,
            matchData.matchedAmount,
            matchData.rate,
            matchData.maturity,
            matchData.lenderSettlementFee,
            matchData.borrowerSettlementFee
        );
    }

    /// @notice Validate match data
    /// @param matchData The match data to validate
    function _validateMatchData(MatchData calldata matchData) internal pure {
        if (matchData.matchId == bytes32(0)) revert InvalidMatchData();
        if (matchData.lender == address(0)) revert InvalidMatchData();
        if (matchData.borrower == address(0)) revert InvalidMatchData();
        if (matchData.loanToken == address(0)) revert InvalidMatchData();
        if (matchData.matchedAmount == 0) revert InvalidMatchData();
        if (matchData.maturity == 0) revert InvalidMatchData();
        if (matchData.timestamp == 0) revert InvalidMatchData();
        if (matchData.lender == matchData.borrower) revert InvalidMatchData();
    }

    // ============ Administrative Functions ============

    /// @notice Update the operator address
    /// @dev Only callable by owner
    /// @param newOperator The new operator address
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();

        address oldOperator = _operator;
        _operator = newOperator;

        emit OperatorUpdated(oldOperator, newOperator);
    }

    /// @notice Update the Centuari contract address
    /// @dev Only callable by owner
    /// @param newCentuari The new Centuari contract address
    function setCentuari(address newCentuari) external onlyOwner {
        if (newCentuari == address(0)) revert ZeroAddress();

        address oldCentuari = _centuari;
        _centuari = newCentuari;

        emit CentuariUpdated(oldCentuari, newCentuari);
    }

    /// @notice Pause the contract
    /// @dev Only callable by owner. Prevents settlement functions from executing.
    function pause() external onlyOwner {
        _paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the contract
    /// @dev Only callable by owner. Allows settlement functions to execute.
    function unpause() external onlyOwner {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    // ============ View Functions ============

    /// @inheritdoc ISettlement
    function isSettled(bytes32 matchId) external view returns (bool) {
        return _settledMatches[matchId];
    }

    /// @inheritdoc ISettlement
    function operator() external view returns (address) {
        return _operator;
    }

    /// @inheritdoc ISettlement
    function centuari() external view returns (address) {
        return _centuari;
    }

    /// @notice Check if the contract is paused
    /// @return True if the contract is paused
    function paused() external view returns (bool) {
        return _paused;
    }
}
