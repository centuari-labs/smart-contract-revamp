// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

/// @title DeployScriptBase
/// @notice Shared base for hub deploy scripts. Holds the one piece of boilerplate
///         every proxy deployment repeats: reading the ProxyAdmin out of a
///         TransparentUpgradeableProxy. `vm` is inherited from `Script`, so no extra
///         import is needed.
abstract contract DeployScriptBase is Script {
    /// @notice Get the ProxyAdmin address from a TransparentUpgradeableProxy
    /// @dev Reads the admin address from the ERC1967 admin slot.
    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        bytes32 adminValue = vm.load(proxy, adminSlot);
        return address(uint160(uint256(adminValue)));
    }
}
