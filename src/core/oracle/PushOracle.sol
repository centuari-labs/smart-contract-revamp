// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceFeed} from "../../interfaces/IPriceFeed.sol";

/// @title PushOracle
/// @notice Operator-pushed `IPriceFeed` for assets without a live market feed
///         (RWA / synthetics: IDRX, XSGD, XAUT, SLVon, NVDAon, AAPLon, TLTon).
/// @dev Prices are pushed already 1e18-scaled (USD per whole token) and stamped
///      with `block.timestamp`, so the router's staleness gate fail-closes if
///      the operator stops pushing. This is also the drop-in template for a
///      future in-house oracle: anything implementing `IPriceFeed` plugs into
///      the router via one `setFeed` call — no router or RiskModule changes.
///
///      SC-2 hardening: every push is sanity-checked against owner-settable
///      [minPrice, maxPrice] absolute bounds AND a max per-update deviation
///      (the first push after deploy is exempt — no prior price to compare).
///      Defaults are generous (min = 1, max = unbounded, deviation = 50%) so
///      the operator can run normally; the owner tightens bounds per asset.
///      TRUST MODEL: `owner` and `operator` are trusted roles. Before mainnet
///      both should migrate to a multisig/timelock (governance follow-up — not
///      implemented this phase).
contract PushOracle is IPriceFeed, Ownable {
    uint256 private constant BPS = 1e4;

    /// @notice Default max per-update price move (50%) until the owner tightens it.
    uint256 private constant DEFAULT_MAX_DEVIATION_BPS = 5000;

    uint256 private _price1e18;
    uint256 private _updatedAt;
    address private _operator;

    /// @notice Absolute price sanity bounds (SC-2). Owner-settable; generous by default.
    uint256 private _minPrice;
    uint256 private _maxPrice;

    /// @notice Max allowed per-update price move in basis points (SC-2).
    /// @dev The first push after deploy is exempt (no prior price to compare).
    uint256 private _maxDeviationBps;

    event PriceUpdated(uint256 price1e18, uint256 updatedAt);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event PriceBoundsUpdated(uint256 minPrice, uint256 maxPrice);
    event MaxDeviationUpdated(uint256 oldBps, uint256 newBps);

    error ZeroAddress();
    error NotOperator();
    error InvalidBounds();
    error InvalidDeviation();
    error PriceOutOfBounds();
    error PriceDeviationTooLarge();

    modifier onlyOperator() {
        if (msg.sender != _operator) revert NotOperator();
        _;
    }

    /// @param owner_ Governance owner (can rotate the operator + set price bounds)
    /// @param operator_ The key allowed to push prices (backend operator)
    constructor(address owner_, address operator_) Ownable(owner_) {
        if (operator_ == address(0)) revert ZeroAddress();
        _operator = operator_;
        emit OperatorUpdated(address(0), operator_);

        // SC-2: generous, owner-tunable defaults. min = 1 rejects a zero/garbage
        // push; max = unbounded until the owner tightens per asset; the 50%
        // per-update deviation guard is active immediately (first push exempt).
        _minPrice = 1;
        _maxPrice = type(uint256).max;
        _maxDeviationBps = DEFAULT_MAX_DEVIATION_BPS;
        emit PriceBoundsUpdated(1, type(uint256).max);
        emit MaxDeviationUpdated(0, DEFAULT_MAX_DEVIATION_BPS);
    }

    /// @notice Push a fresh price (1e18-scaled USD per whole token).
    /// @dev SC-2: bounded by [minPrice, maxPrice] and, after the first push, by
    ///      the max per-update deviation relative to the last pushed price.
    function setPrice(uint256 price1e18) external onlyOperator {
        if (price1e18 < _minPrice || price1e18 > _maxPrice) revert PriceOutOfBounds();

        uint256 prev = _price1e18;
        if (_updatedAt != 0) {
            // Reject out-of-band jumps vs the last pushed price (prev >= minPrice >= 1).
            uint256 maxDelta = Math.mulDiv(prev, _maxDeviationBps, BPS);
            uint256 lower = prev > maxDelta ? prev - maxDelta : 0;
            if (price1e18 > prev + maxDelta || price1e18 < lower) revert PriceDeviationTooLarge();
        }

        _price1e18 = price1e18;
        _updatedAt = block.timestamp;
        emit PriceUpdated(price1e18, block.timestamp);
    }

    /// @notice Rotate the price-pushing operator.
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        address old = _operator;
        _operator = newOperator;
        emit OperatorUpdated(old, newOperator);
    }

    /// @notice Set absolute price sanity bounds (SC-2). Owner-only.
    function setBounds(uint256 minPrice_, uint256 maxPrice_) external onlyOwner {
        if (minPrice_ == 0 || minPrice_ >= maxPrice_) revert InvalidBounds();
        _minPrice = minPrice_;
        _maxPrice = maxPrice_;
        emit PriceBoundsUpdated(minPrice_, maxPrice_);
    }

    /// @notice Set the max per-update price deviation in basis points (SC-2). Owner-only.
    function setMaxDeviationBps(uint256 maxDeviationBps_) external onlyOwner {
        if (maxDeviationBps_ == 0) revert InvalidDeviation();
        uint256 old = _maxDeviationBps;
        _maxDeviationBps = maxDeviationBps_;
        emit MaxDeviationUpdated(old, maxDeviationBps_);
    }

    /// @inheritdoc IPriceFeed
    function latestPriceUsd() external view returns (uint256 price1e18, uint256 updatedAt) {
        return (_price1e18, _updatedAt);
    }

    /// @notice The current price-pushing operator.
    function operator() external view returns (address) {
        return _operator;
    }

    /// @notice Current absolute price sanity bounds [min, max] (SC-2).
    function priceBounds() external view returns (uint256 minPrice, uint256 maxPrice) {
        return (_minPrice, _maxPrice);
    }

    /// @notice Max allowed per-update price move in basis points (SC-2).
    function maxDeviationBps() external view returns (uint256) {
        return _maxDeviationBps;
    }
}
