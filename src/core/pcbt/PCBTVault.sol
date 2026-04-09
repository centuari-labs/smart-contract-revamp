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
import {IBalanceLedger} from "../../interfaces/IBalanceLedger.sol";
import {PCBTVaultStorage} from "./PCBTVaultStorage.sol";

/// @title PCBTVault
/// @notice Perpetual CBT Vault — wraps CBT into a perpetual composable ERC-20 token.
/// @dev Redesigned post-architecture-overhaul:
///      - Deposit USDC (new users) or CBT (existing lenders joining midway)
///      - Per-user rollover settings (MARKET vs TARGET rate, custom maturity, max rollovers)
///      - Instant withdrawal → returns proportional CBT + idle USDC (no queue)
///      - Vault is a BalanceLedger user → idle USDC earns yield via YieldRouter
///      - At maturity: engine processes each user per THEIR settings (ROLL or RETURN)
///      - ERC-4626 inflation defense: virtual shares with 6-decimal offset
contract PCBTVault is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PCBTVaultStorage,
    IPCBT
{
    using SafeERC20 for IERC20;

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
        address balanceLedger_,
        address endpoint_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        if (loanToken_ == address(0) || balanceLedger_ == address(0) || endpoint_ == address(0)) {
            revert ZeroAddress();
        }

        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _loanToken = loanToken_;
        _rateOracle = rateOracle_;
        _balanceLedger = balanceLedger_;
        _endpoint = endpoint_;

        // Seed deposit: mint VIRTUAL_OFFSET shares to dead address for inflation defense
        _mint(address(1), VIRTUAL_OFFSET);
    }

    // ============ Modifiers ============

    modifier onlyEndpoint() {
        if (msg.sender != _endpoint) revert OnlyEndpoint();
        _;
    }

    // ============ User Functions: Deposit ============

    /// @inheritdoc IPCBT
    function deposit(uint256 usdcAmount) external override nonReentrant returns (uint256 pCBTMinted) {
        if (usdcAmount == 0) revert ZeroAmount();

        // Transfer USDC from user → vault (fee-on-transfer safe)
        uint256 balBefore = IERC20(_loanToken).balanceOf(address(this));
        IERC20(_loanToken).safeTransferFrom(msg.sender, address(this), usdcAmount);
        uint256 received = IERC20(_loanToken).balanceOf(address(this)) - balBefore;

        // Deposit USDC to BalanceLedger (vault as depositor — engine will lend it)
        IERC20(_loanToken).forceApprove(_balanceLedger, received);
        IBalanceLedger(_balanceLedger).deposit(_loanToken, received);

        // Compute pCBT shares with virtual offset for inflation defense
        uint256 totalValue = _totalVaultValue();
        uint256 supply = totalSupply();
        pCBTMinted = (received * (supply + VIRTUAL_OFFSET)) / (totalValue + VIRTUAL_OFFSET);

        _mint(msg.sender, pCBTMinted);

        // Default rollover settings for new depositors (Easy Mode: ON)
        if (!_userSettings[msg.sender].autoRollover && _userSettings[msg.sender].ratePreference == 0) {
            _userSettings[msg.sender].autoRollover = true;
        }

        emit Deposited(msg.sender, received, pCBTMinted);
    }

    /// @inheritdoc IPCBT
    function depositCBT(uint256 cbtAmount) external override nonReentrant returns (uint256 pCBTMinted) {
        if (cbtAmount == 0) revert ZeroAmount();
        if (_currentCBT == address(0)) revert NoCBTSet();

        // Transfer CBT from user → vault (must match current maturity, fee-on-transfer safe)
        uint256 balBefore = IERC20(_currentCBT).balanceOf(address(this));
        IERC20(_currentCBT).safeTransferFrom(msg.sender, address(this), cbtAmount);
        uint256 received = IERC20(_currentCBT).balanceOf(address(this)) - balBefore;

        // Compute shares
        uint256 totalValue = _totalVaultValue();
        uint256 supply = totalSupply();
        pCBTMinted = (received * (supply + VIRTUAL_OFFSET)) / (totalValue + VIRTUAL_OFFSET);

        _totalCBTHeld += received;
        _mint(msg.sender, pCBTMinted);

        // Default rollover settings
        if (!_userSettings[msg.sender].autoRollover && _userSettings[msg.sender].ratePreference == 0) {
            _userSettings[msg.sender].autoRollover = true;
        }

        emit CBTDeposited(msg.sender, received, pCBTMinted);
    }

    // ============ User Functions: Withdraw ============

    /// @inheritdoc IPCBT
    function withdraw(uint256 shares) external override nonReentrant returns (uint256 cbtAmount, uint256 usdcAmount) {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        uint256 supply = totalSupply();

        // Proportional CBT
        cbtAmount = (shares * _totalCBTHeld) / supply;

        // Proportional idle USDC (in BalanceLedger)
        uint256 idleUSDC = _getIdleUSDC();
        usdcAmount = (shares * idleUSDC) / supply;

        // Burn shares
        _burn(msg.sender, shares);

        // Transfer CBT to user's wallet
        if (cbtAmount > 0 && _currentCBT != address(0)) {
            _totalCBTHeld -= cbtAmount;
            IERC20(_currentCBT).safeTransfer(msg.sender, cbtAmount);
        }

        // Credit idle USDC to user's BalanceLedger available
        if (usdcAmount > 0) {
            IBalanceLedger(_balanceLedger).credit(msg.sender, _loanToken, usdcAmount);
        }

        emit Withdrawn(msg.sender, shares, cbtAmount, usdcAmount);
    }

    // ============ User Functions: Rollover Settings ============

    /// @inheritdoc IPCBT
    function setRolloverSettings(RolloverSettings calldata settings) external override {
        // Lock settings 1 hour before maturity
        if (_nextMaturity > SETTINGS_LOCK_DURATION && block.timestamp > _nextMaturity - SETTINGS_LOCK_DURATION) {
            revert SettingsLocked();
        }

        _userSettings[msg.sender] = settings;
        emit RolloverSettingsUpdated(msg.sender);
    }

    // ============ Engine Functions (Endpoint Only) ============

    /// @inheritdoc IPCBT
    function processMaturityResults(
        MaturityResult[] calldata results,
        address newCBT
    ) external override onlyEndpoint nonReentrant {
        address oldCBT = _currentCBT;

        // Update vault CBT tracking
        _currentCBT = newCBT;
        if (newCBT != address(0)) {
            _nextMaturity = ICBT(newCBT).maturity();
        }

        uint256 newTotalCBT = 0;

        for (uint256 i = 0; i < results.length; i++) {
            MaturityResult calldata r = results[i];

            if (r.outcome == 0) {
                // ROLL: user stays in vault. CBT amount accumulates.
                newTotalCBT += r.cbtAmount;
                _userSettings[r.user].rolloverCount++;
            } else {
                // RETURN: burn pCBT, credit USDC to BalanceLedger
                // Gracefully skip if user already withdrew
                if (balanceOf(r.user) == 0) continue;

                uint256 sharesToBurn = r.sharesBurned > balanceOf(r.user)
                    ? balanceOf(r.user)
                    : r.sharesBurned;

                if (sharesToBurn > 0) {
                    _burn(r.user, sharesToBurn);
                }

                if (r.usdcReturned > 0) {
                    IBalanceLedger(_balanceLedger).credit(r.user, _loanToken, r.usdcReturned);
                }
            }
        }

        _totalCBTHeld = newTotalCBT;

        // Verify vault actually holds the CBT it claims
        if (newCBT != address(0) && newTotalCBT > 0) {
            require(
                IERC20(newCBT).balanceOf(address(this)) >= newTotalCBT,
                "PCBTVault: CBT balance mismatch"
            );
        }

        emit MaturityProcessed(oldCBT, newCBT, newTotalCBT);
    }

    // ============ Emergency ============

    /// @notice Emergency wind-down if maturity processing fails
    /// @dev Callable by owner after maturity + 48h grace. Redeems expired CBT for USDC.
    function emergencyWindDown() external onlyOwner nonReentrant {
        if (_nextMaturity == 0 || block.timestamp < _nextMaturity + EMERGENCY_GRACE_PERIOD) {
            revert EmergencyNotReady();
        }

        if (_currentCBT != address(0) && _totalCBTHeld > 0) {
            uint256 cbtBefore = _totalCBTHeld;
            uint256 redeemed = ICBT(_currentCBT).redeem(_totalCBTHeld);
            _totalCBTHeld = 0;

            // Deposit recovered USDC to BalanceLedger for proportional user claims
            IERC20(_loanToken).forceApprove(_balanceLedger, redeemed);
            IBalanceLedger(_balanceLedger).deposit(_loanToken, redeemed);

            emit EmergencyWindDown(cbtBefore, redeemed);
        }
    }

    /// @notice Sweep donated tokens above internal tracking
    function sweep(address token) external onlyOwner {
        if (token == _currentCBT && _currentCBT != address(0)) {
            uint256 excess = IERC20(token).balanceOf(address(this)) - _totalCBTHeld;
            if (excess > 0) IERC20(token).safeTransfer(owner(), excess);
        } else if (token != _loanToken) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) IERC20(token).safeTransfer(owner(), bal);
        }
    }

    // ============ View ============

    /// @inheritdoc IPCBT
    function sharePrice() external view override returns (uint256 price) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        uint256 totalValue = _getCBTFairValue() + _getIdleUSDC();
        price = (totalValue * 1e18) / supply;
    }

    /// @inheritdoc IPCBT
    function getUserSettings(address user) external view override returns (RolloverSettings memory) {
        return _userSettings[user];
    }

    /// @inheritdoc IPCBT
    function nextMaturityDate() external view override returns (uint256) {
        return _nextMaturity;
    }

    /// @inheritdoc IPCBT
    function totalAssets() external view override returns (uint256 cbtHeld, uint256 cbtFairValueUSD, uint256 idleUSDC) {
        cbtHeld = _totalCBTHeld;
        cbtFairValueUSD = _getCBTFairValue();
        idleUSDC = _getIdleUSDC();
    }

    /// @inheritdoc IPCBT
    function loanToken() external view override returns (address) {
        return _loanToken;
    }

    function currentCBTAddress() external view returns (address) {
        return _currentCBT;
    }

    // ============ Internal ============

    function _totalVaultValue() internal view returns (uint256) {
        return _totalCBTHeld + _getIdleUSDC();
    }

    function _getIdleUSDC() internal view returns (uint256) {
        if (_balanceLedger == address(0)) return 0;
        try IBalanceLedger(_balanceLedger).getAvailable(address(this), _loanToken) returns (uint256 avail) {
            return avail;
        } catch {
            return 0;
        }
    }

    function _getCBTFairValue() internal view returns (uint256) {
        if (_currentCBT == address(0) || _rateOracle == address(0) || _totalCBTHeld == 0) {
            return _totalCBTHeld;
        }

        try ICentuariRateOracle(_rateOracle).getCBTFairValue(_currentCBT) returns (uint256 fairValue) {
            return (_totalCBTHeld * fairValue) / 1e18;
        } catch {
            // Conservative fallback: 95% of face value
            return (_totalCBTHeld * 95) / 100;
        }
    }

    // ============ Administrative (48h Timelock) ============

    function proposeEndpoint(address endpoint_) external onlyOwner {
        require(endpoint_ != address(0), "PCBTVault: zero address");
        bytes32 key = keccak256("endpoint");
        _pendingAdminAddress[key] = endpoint_;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    function applyEndpoint() external onlyOwner {
        bytes32 key = keccak256("endpoint");
        require(_pendingAdminAddress[key] != address(0), "PCBTVault: no pending");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "PCBTVault: timelock active");
        _endpoint = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    function proposeRateOracle(address oracle_) external onlyOwner {
        require(oracle_ != address(0), "PCBTVault: zero address");
        bytes32 key = keccak256("rateOracle");
        _pendingAdminAddress[key] = oracle_;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    function applyRateOracle() external onlyOwner {
        bytes32 key = keccak256("rateOracle");
        require(_pendingAdminAddress[key] != address(0), "PCBTVault: no pending");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "PCBTVault: timelock active");
        _rateOracle = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }
}
