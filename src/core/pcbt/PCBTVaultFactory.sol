// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PCBTVault} from "./PCBTVault.sol";

/// @title PCBTVaultFactory
/// @notice Deploys new pCBT vaults per stablecoin denomination
/// @dev Each loanToken gets exactly one vault. Deploys ERC1967 proxy + PCBTVault implementation.
contract PCBTVaultFactory is Ownable {
    /// @notice Shared PCBTVault implementation contract
    address public immutable implementation;

    /// @notice Mapping: loanToken => vault proxy address
    mapping(address => address) public vaults;

    /// @notice All deployed vault addresses
    address[] public allVaults;

    /// @notice ProxyAdmin address for upgrade control
    address public proxyAdmin;

    event VaultCreated(address indexed loanToken, address indexed vault);

    error VaultAlreadyExists(address loanToken);
    error ZeroAddress();

    constructor(address owner_, address proxyAdmin_) Ownable(owner_) {
        if (proxyAdmin_ == address(0)) revert ZeroAddress();
        implementation = address(new PCBTVault());
        proxyAdmin = proxyAdmin_;
    }

    /// @notice Create a new pCBT vault for a stablecoin denomination
    /// @param loanToken The underlying stablecoin (USDC, IDRX, XSGD)
    /// @param rateOracle CentuariRateOracle address
    /// @param balanceLedger BalanceLedger address (vault deposits idle USDC here)
    /// @param endpoint CentuariEndpoint address
    /// @param name ERC-20 token name (e.g., "Perpetual CBT USDC")
    /// @param symbol ERC-20 token symbol (e.g., "pCBT-USDC")
    /// @return vault The deployed vault proxy address
    function createVault(
        address loanToken,
        address rateOracle,
        address balanceLedger,
        address endpoint,
        string calldata name,
        string calldata symbol
    ) external onlyOwner returns (address vault) {
        if (vaults[loanToken] != address(0)) revert VaultAlreadyExists(loanToken);
        if (loanToken == address(0)) revert ZeroAddress();

        bytes memory initData = abi.encodeCall(
            PCBTVault.initialize,
            (msg.sender, loanToken, rateOracle, balanceLedger, endpoint, name, symbol)
        );

        vault = address(new TransparentUpgradeableProxy(
            implementation,
            proxyAdmin,
            initData
        ));

        vaults[loanToken] = vault;
        allVaults.push(vault);

        emit VaultCreated(loanToken, vault);
    }

    /// @notice Get vault address for a loan token
    function getVault(address loanToken) external view returns (address) {
        return vaults[loanToken];
    }

    /// @notice Get total number of deployed vaults
    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }
}
