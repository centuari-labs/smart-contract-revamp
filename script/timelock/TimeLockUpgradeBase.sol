// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title TimeLockUpgradeBase
/// @notice Abstract contract with shared calldata helpers for TimeLock-governed proxy upgrades.
/// @dev No state variables. No vm.* cheatcodes. Purely internal pure/view helpers.
///      All external calls (TimelockController.schedule, .execute, .cancel) are made in
///      the inheriting Script contracts within vm.startBroadcast/stopBroadcast context.
///
///      Hierarchy:
///        TimeLockUpgradeBase  ← pure/view helpers, no vm.*
///            ↑
///        UpgradeScriptBase    ← adds Script + vm.* JSON helpers + shared run* functions
///            ↑
///        Upgrade<Contract>    ← only _contractName() + _deployNewImplementation()
abstract contract TimeLockUpgradeBase {
    // ─────────────────────────── Calldata Helpers ──────────────────────────── //

    /// @notice Build the calldata to upgrade a TransparentUpgradeableProxy via ProxyAdmin.
    /// @param proxy     The proxy address to upgrade.
    /// @param newImpl   The new implementation address.
    /// @param initData  Initialization calldata (empty bytes for simple upgrades).
    /// @return Encoded calldata for ProxyAdmin.upgradeAndCall(proxy, newImpl, initData).
    function _buildUpgradeCalldata(address proxy, address newImpl, bytes memory initData)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(proxy), newImpl, initData));
    }

    // ────────────────────────── Operation ID Helper ─────────────────────────── //

    /// @notice Compute the TimelockController operation ID, replicating OZ v5 hashOperation.
    /// @dev OZ v5 hashOperation encodes all 5 parameters:
    ///        keccak256(abi.encode(target, value, data, predecessor, salt))
    ///      with value=0 and predecessor=bytes32(0) encoded explicitly.
    ///      This must remain byte-for-byte identical with on-chain hashOperation() to avoid
    ///      operationId mismatches between runSchedule and runExecute.
    /// @param target The target contract (ProxyAdmin address for upgrade operations).
    /// @param data   The operation calldata.
    /// @param salt   The unique salt for this operation.
    /// @return operationId The keccak256 hash identifying this operation.
    function _computeOperationId(address target, bytes memory data, bytes32 salt)
        internal
        pure
        returns (bytes32 operationId)
    {
        return keccak256(abi.encode(target, uint256(0), data, bytes32(0), salt));
    }

    // ────────────────────────── TimeLock View Helper ─────────────────────────── //

    /// @notice Read the minimum delay from a deployed TimelockController.
    /// @param timeLock The TimelockController address.
    /// @return The minimum delay in seconds.
    function _getMinDelay(address timeLock) internal view returns (uint256) {
        return TimelockController(payable(timeLock)).getMinDelay();
    }
}
