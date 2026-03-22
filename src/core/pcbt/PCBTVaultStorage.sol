// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPCBT} from "../../interfaces/IPCBT.sol";

/// @title PCBTVaultStorage
/// @notice Storage layout for PCBTVault upgradeable contract
abstract contract PCBTVaultStorage {
    /// @notice Underlying loan token (USDC, IDRX, XSGD)
    address internal _loanToken;

    /// @notice Current active CBT contract held by vault
    address internal _currentCBT;

    /// @notice CentuariRateOracle for CBT fair value reads
    address internal _rateOracle;

    /// @notice CentuariRouter for submitting lend intents
    address internal _router;

    /// @notice CentuariEndpoint — authorized caller for onSettlement
    address internal _endpoint;

    /// @notice Idle loan token balance not yet deployed to CBT (internal tracking, NOT balanceOf)
    uint256 internal _idleBalance;

    /// @notice Sum of all CBT face value held by vault
    uint256 internal _totalCBTFaceValue;

    /// @notice FIFO withdrawal queue
    IPCBT.WithdrawalRequest[] internal _withdrawalQueue;

    /// @notice Early exit requests per user
    mapping(address => IPCBT.EarlyExitRequest) internal _earlyExitRequests;

    /// @notice Pending withdrawal per user (tracks index in queue, 0 = no pending)
    mapping(address => uint256) internal _pendingWithdrawalIndex;

    /// @notice Withdrawal cutoff: seconds before maturity when new requests are rejected
    uint256 internal _withdrawalCutoffSeconds;

    /// @notice Next maturity timestamp (used for withdrawal cutoff enforcement)
    uint256 internal _nextMaturity;

    // ============ Gap ============

    uint256[40] private __gap;
}
