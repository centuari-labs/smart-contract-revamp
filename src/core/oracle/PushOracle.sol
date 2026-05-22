// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceFeed} from "../../interfaces/IPriceFeed.sol";

/// @title PushOracle
/// @notice Operator-pushed `IPriceFeed` for assets without a live market feed
///         (RWA / synthetics: IDRX, XSGD, XAUT, SLVon, NVDAon, AAPLon, TLTon).
/// @dev Prices are pushed already 1e18-scaled (USD per whole token) and stamped
///      with `block.timestamp`, so the router's staleness gate fail-closes if
///      the operator stops pushing. This is also the drop-in template for a
///      future in-house oracle: anything implementing `IPriceFeed` plugs into
///      the router via one `setFeed` call — no router or RiskModule changes.
contract PushOracle is IPriceFeed, Ownable {
    uint256 private _price1e18;
    uint256 private _updatedAt;
    address private _operator;

    event PriceUpdated(uint256 price1e18, uint256 updatedAt);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    error ZeroAddress();
    error NotOperator();

    modifier onlyOperator() {
        if (msg.sender != _operator) revert NotOperator();
        _;
    }

    /// @param owner_ Governance owner (can rotate the operator)
    /// @param operator_ The key allowed to push prices (backend operator)
    constructor(address owner_, address operator_) Ownable(owner_) {
        if (operator_ == address(0)) revert ZeroAddress();
        _operator = operator_;
        emit OperatorUpdated(address(0), operator_);
    }

    /// @notice Push a fresh price (1e18-scaled USD per whole token).
    function setPrice(uint256 price1e18) external onlyOperator {
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

    /// @inheritdoc IPriceFeed
    function latestPriceUsd() external view returns (uint256 price1e18, uint256 updatedAt) {
        return (_price1e18, _updatedAt);
    }

    /// @notice The current price-pushing operator.
    function operator() external view returns (address) {
        return _operator;
    }
}
