// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";
import {IPriceFeed} from "../../interfaces/IPriceFeed.sol";
import {OracleRouterStorage} from "./OracleRouterStorage.sol";

/// @title OracleRouter
/// @notice Provider-agnostic USD oracle: routes each asset to its `IPriceFeed`
///         source and returns fail-closed 1e18 USD values for the RiskModule.
/// @dev Implements `IPriceOracle`. Holds NO vendor types — any `IPriceFeed`
///      (Chainlink adapter, `PushOracle`, or a future in-house oracle) plugs in
///      via `setFeed`. Every external read is wrapped so a missing feed, stale
///      price, non-positive price, exotic token decimals, or a reverting source
///      yields `(0, false)` rather than reverting.
contract OracleRouter is Initializable, OwnableUpgradeable, OracleRouterStorage, IPriceOracle {
    /// @notice Largest token-decimals value the router will price (guards
    ///         `10 ** dec` from overflowing and keeps the read non-reverting).
    uint8 internal constant MAX_TOKEN_DECIMALS = 36;

    event FeedUpdated(address indexed asset, address indexed oldFeed, address indexed newFeed);
    event MaxStalenessUpdated(address indexed asset, uint256 oldSeconds, uint256 newSeconds);

    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param owner_ Governance owner allowed to register feeds + staleness.
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
    }

    // ============ Governance ============

    /// @notice Point `asset` at a price source (`address(0)` to unregister).
    function setFeed(address asset, address feed) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        address old = address(_feeds[asset]);
        _feeds[asset] = IPriceFeed(feed);
        emit FeedUpdated(asset, old, feed);
    }

    /// @notice Set the max acceptable price age for `asset` (0 = no staleness gate).
    function setMaxStaleness(address asset, uint256 maxSeconds) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        uint256 old = _maxStaleness[asset];
        _maxStaleness[asset] = maxSeconds;
        emit MaxStalenessUpdated(asset, old, maxSeconds);
    }

    // ============ Oracle read ============

    /// @inheritdoc IPriceOracle
    function tryGetUsdValue(address asset, uint256 amount) external view returns (uint256 value1e18, bool ok) {
        IPriceFeed feed = _feeds[asset];
        if (address(feed) == address(0)) return (0, false);

        try feed.latestPriceUsd() returns (uint256 price1e18, uint256 updatedAt) {
            if (price1e18 == 0 || updatedAt == 0) return (0, false);

            uint256 maxAge = _maxStaleness[asset];
            if (maxAge != 0 && block.timestamp > updatedAt + maxAge) return (0, false);

            try IERC20Metadata(asset).decimals() returns (uint8 dec) {
                if (dec > MAX_TOKEN_DECIMALS) return (0, false);
                return (Math.mulDiv(amount, price1e18, 10 ** dec), true);
            } catch {
                return (0, false);
            }
        } catch {
            return (0, false);
        }
    }

    // ============ Views ============

    /// @notice The registered price source for `asset` (`address(0)` if none).
    function feedOf(address asset) external view returns (address) {
        return address(_feeds[asset]);
    }

    /// @notice The max price age for `asset` in seconds (0 = disabled).
    function maxStalenessOf(address asset) external view returns (uint256) {
        return _maxStaleness[asset];
    }
}
