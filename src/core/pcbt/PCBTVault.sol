// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../../utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPCBT} from "../../interfaces/IPCBT.sol";
import {ICBT} from "../../interfaces/ICBT.sol";
import {ICentuariRateOracle} from "../../interfaces/ICentuariRateOracle.sol";
import {PCBTVaultStorage} from "./PCBTVaultStorage.sol";

/// @title PCBTVault
/// @notice Perpetual CBT Vault — wraps CBT into a perpetual composable ERC-20 token
/// @dev One vault per stablecoin denomination. Users deposit CBT, receive pCBT 1:1 with
///      CBT face value. The vault auto-rolls CBT at maturity via CentuariEndpoint.
///      ERC-4626 inflation defense: virtual shares with 6-decimal offset + internal balance tracking.
contract PCBTVault is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PCBTVaultStorage,
    IPCBT
{
    using SafeERC20 for IERC20;

    /// @notice Virtual offset for inflation attack defense (10^6)
    uint256 private constant VIRTUAL_OFFSET = 1e6;

    /// @notice Default withdrawal cutoff: 24 hours before maturity
    uint256 private constant DEFAULT_CUTOFF_SECONDS = 24 hours;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    function initialize(
        address owner_,
        address loanToken_,
        address rateOracle_,
        address router_,
        address endpoint_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        if (loanToken_ == address(0) || rateOracle_ == address(0) ||
            router_ == address(0) || endpoint_ == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _loanToken = loanToken_;
        _rateOracle = rateOracle_;
        _router = router_;
        _endpoint = endpoint_;
        _withdrawalCutoffSeconds = DEFAULT_CUTOFF_SECONDS;

        // Seed deposit: mint VIRTUAL_OFFSET shares to dead address for inflation defense
        _mint(address(1), VIRTUAL_OFFSET);
    }

    // ============ Modifiers ============

    modifier onlyEndpoint() {
        if (msg.sender != _endpoint) revert OnlyEndpoint();
        _;
    }

    // ============ Core Functions ============

    /// @inheritdoc IPCBT
    function depositCBT(uint256 cbtAmount) external override nonReentrant returns (uint256 pCBTMinted) {
        if (cbtAmount == 0) revert ZeroAmount();
        if (_currentCBT == address(0)) revert ZeroAddress();

        // Transfer CBT from user to vault
        IERC20(_currentCBT).safeTransferFrom(msg.sender, address(this), cbtAmount);

        // Compute shares using virtual offset for inflation defense
        // shares = cbtAmount * (totalSupply + VIRTUAL_OFFSET) / (totalCBTValue + VIRTUAL_OFFSET)
        uint256 totalCBTValue = _totalCBTFaceValue + _idleBalance;
        uint256 supply = totalSupply();

        pCBTMinted = (cbtAmount * (supply + VIRTUAL_OFFSET)) / (totalCBTValue + VIRTUAL_OFFSET);

        _totalCBTFaceValue += cbtAmount;
        _mint(msg.sender, pCBTMinted);

        emit CBTDeposited(msg.sender, cbtAmount, pCBTMinted);
    }

    /// @inheritdoc IPCBT
    function requestWithdrawal(uint256 shares) external override nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();
        if (_pendingWithdrawalIndex[msg.sender] != 0) revert WithdrawalAlreadyPending();

        // Enforce withdrawal cutoff: cannot request within _withdrawalCutoffSeconds of maturity
        if (_nextMaturity > 0 && block.timestamp > _nextMaturity - _withdrawalCutoffSeconds) {
            revert WithdrawalCutoffPassed();
        }

        _withdrawalQueue.push(WithdrawalRequest({
            user: msg.sender,
            shares: shares,
            requestedAt: block.timestamp
        }));

        // Store 1-indexed position (0 means no pending)
        _pendingWithdrawalIndex[msg.sender] = _withdrawalQueue.length;

        emit WithdrawalRequested(msg.sender, shares);
    }

    /// @inheritdoc IPCBT
    function cancelWithdrawal() external override nonReentrant {
        uint256 idx = _pendingWithdrawalIndex[msg.sender];
        if (idx == 0) revert NoWithdrawalPending();

        uint256 arrayIdx = idx - 1;
        uint256 shares = _withdrawalQueue[arrayIdx].shares;

        // Move last element to this slot (swap-and-pop)
        uint256 lastIdx = _withdrawalQueue.length - 1;
        if (arrayIdx != lastIdx) {
            WithdrawalRequest memory last = _withdrawalQueue[lastIdx];
            _withdrawalQueue[arrayIdx] = last;
            _pendingWithdrawalIndex[last.user] = idx; // Update moved element's index
        }
        _withdrawalQueue.pop();
        _pendingWithdrawalIndex[msg.sender] = 0;

        emit WithdrawalCancelled(msg.sender, shares);
    }

    /// @inheritdoc IPCBT
    function requestEarlyExit(uint256 shares, uint8 orderType, uint256 minPrice) external override nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();
        if (_earlyExitRequests[msg.sender].active) revert EarlyExitAlreadyPending();

        _earlyExitRequests[msg.sender] = EarlyExitRequest({
            shares: shares,
            orderType: orderType,
            minPrice: minPrice,
            active: true
        });

        emit EarlyExitRequested(msg.sender, shares, orderType, minPrice);
    }

    /// @inheritdoc IPCBT
    function cancelEarlyExit() external override nonReentrant {
        if (!_earlyExitRequests[msg.sender].active) revert NoEarlyExitPending();

        delete _earlyExitRequests[msg.sender];

        emit EarlyExitCancelled(msg.sender);
    }

    // ============ Settlement (Endpoint Only) ============

    /// @inheritdoc IPCBT
    function onSettlement(
        address newCBT,
        uint256 newCBTAmount,
        uint256 redeemedUSDC
    ) external override onlyEndpoint nonReentrant {
        address oldCBT = _currentCBT;

        // Update to new CBT
        _currentCBT = newCBT;
        _idleBalance += redeemedUSDC;
        _totalCBTFaceValue = newCBTAmount;

        // Update next maturity from new CBT contract
        if (newCBT != address(0)) {
            _nextMaturity = ICBT(newCBT).maturity();
        }

        // Process FIFO withdrawal queue
        uint256 withdrawalsPaid = _processWithdrawalQueue();

        emit MaturityProcessed(oldCBT, newCBT, newCBTAmount, withdrawalsPaid);
    }

    // ============ Internal ============

    function _processWithdrawalQueue() internal returns (uint256 totalPaid) {
        uint256 availableUSDC = _idleBalance;
        IERC20 token = IERC20(_loanToken);
        uint256 supply = totalSupply();
        uint256 totalValue = _totalCBTFaceValue + _idleBalance;

        uint256 processed = 0;
        for (uint256 i = 0; i < _withdrawalQueue.length && availableUSDC > 0; i++) {
            WithdrawalRequest memory req = _withdrawalQueue[i];

            // Compute proportional USDC: shares / totalSupply * totalValue
            uint256 usdcAmount = (req.shares * totalValue) / supply;
            if (usdcAmount > availableUSDC) {
                usdcAmount = availableUSDC;
            }

            // Burn pCBT shares
            _burn(req.user, req.shares);
            supply -= req.shares;

            // Transfer USDC
            token.safeTransfer(req.user, usdcAmount);
            availableUSDC -= usdcAmount;
            totalPaid += usdcAmount;

            _pendingWithdrawalIndex[req.user] = 0;
            processed++;

            emit WithdrawalFulfilled(req.user, req.shares, usdcAmount);
        }

        // Remove processed entries from queue
        if (processed > 0) {
            if (processed == _withdrawalQueue.length) {
                delete _withdrawalQueue;
            } else {
                // Shift remaining to front
                for (uint256 i = 0; i < _withdrawalQueue.length - processed; i++) {
                    _withdrawalQueue[i] = _withdrawalQueue[i + processed];
                    _pendingWithdrawalIndex[_withdrawalQueue[i].user] = i + 1;
                }
                for (uint256 i = 0; i < processed; i++) {
                    _withdrawalQueue.pop();
                }
            }
        }

        _idleBalance = availableUSDC;
    }

    // ============ View Functions ============

    /// @inheritdoc IPCBT
    function sharePrice() external view override returns (uint256 price) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;

        uint256 totalValue = _getCBTFairValue() + _idleBalance;
        price = (totalValue * 1e18) / supply;
    }

    /// @inheritdoc IPCBT
    function currentCBTAddress() external view override returns (address) {
        return _currentCBT;
    }

    /// @inheritdoc IPCBT
    function collateralValuePerPCBT() external view override returns (uint256 valueUSD) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;

        uint256 totalValue = _getCBTFairValue() + _idleBalance;
        valueUSD = (totalValue * 1e18) / supply;
    }

    /// @inheritdoc IPCBT
    function totalAssets() external view override returns (uint256 cbtHeld, uint256 cbtFairValueUSD, uint256 idleUSDC) {
        cbtHeld = _totalCBTFaceValue;
        cbtFairValueUSD = _getCBTFairValue();
        idleUSDC = _idleBalance;
    }

    /// @inheritdoc IPCBT
    function loanToken() external view override returns (address) {
        return _loanToken;
    }

    /// @inheritdoc IPCBT
    function withdrawalQueueLength() external view override returns (uint256) {
        return _withdrawalQueue.length;
    }

    /// @inheritdoc IPCBT
    function getWithdrawalRequest(uint256 index) external view override returns (WithdrawalRequest memory) {
        return _withdrawalQueue[index];
    }

    function _getCBTFairValue() internal view returns (uint256) {
        if (_currentCBT == address(0) || _rateOracle == address(0)) {
            return _totalCBTFaceValue;
        }

        try ICentuariRateOracle(_rateOracle).getCBTFairValue(_currentCBT) returns (uint256 fairValue) {
            // fairValue is per-CBT in 18 decimals, _totalCBTFaceValue is in asset decimals
            // For simplicity: use face value as the fair value proxy (approaches $1 at maturity)
            return (_totalCBTFaceValue * fairValue) / 1e18;
        } catch {
            return _totalCBTFaceValue;
        }
    }

    // ============ Administrative ============

    function setWithdrawalCutoff(uint256 seconds_) external onlyOwner {
        _withdrawalCutoffSeconds = seconds_;
    }

    function setNextMaturity(uint256 maturity_) external onlyOwner {
        _nextMaturity = maturity_;
    }

    function setCurrentCBT(address cbt_) external onlyOwner {
        _currentCBT = cbt_;
        if (cbt_ != address(0)) {
            _nextMaturity = ICBT(cbt_).maturity();
        }
    }
}
