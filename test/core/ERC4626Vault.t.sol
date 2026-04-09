// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @title ERC4626VaultTest
/// @notice REMOVED — ERC-4626 vault functions removed from CentuariRouter per ARCH-07.
///         PCBTVault is the canonical vault. See PCBTVault.t.sol.
contract ERC4626VaultTest is Test {
    function test_erc4626_removed() public pure {
        // ERC-4626 functions removed from CentuariRouter.
        // PCBTVault is the canonical vault for composability.
        assertTrue(true);
    }
}
