// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Treasury} from "../src/core/Treasury.sol";
import {SupportedTokens} from "./SupportedTokens.sol";

/// @title DeployTreasury
/// @notice Deployment script for Treasury. Grants TOKEN_MANAGER_ROLE to deployer and
///         calls setSupportedToken(token, true) for each token from SupportedTokens.
///         Use run(treasury, centuari) after DeployCentuari to call setCentuariContract on Treasury.
/// @dev Flow: run() -> treasury; DeployCentuari.run(..., treasury, ...) -> centuari; run(treasury, centuari) to wire.
contract DeployTreasury is Script {
    /// @notice Deploy Treasury and set supported tokens.
    /// @return treasury_ Deployed Treasury address (pass to DeployCentuari).
    function run() external returns (address treasury_) {
        vm.startBroadcast();

        treasury_ = deploy();

        vm.stopBroadcast();

        console.log("=== Treasury Deployment Complete ===");
        console.log("Treasury:", treasury_);

        return treasury_;
    }

    /// @notice Call setCentuariContract on an existing Treasury (run after DeployCentuari).
    /// @param treasury Existing Treasury contract address
    /// @param centuari Centuari proxy address (from DeployCentuari)
    function run(address treasury, address centuari) external {
        vm.startBroadcast();

        Treasury(treasury).setCentuariContract(centuari);

        vm.stopBroadcast();

        console.log("=== Treasury setCentuariContract ===");
        console.log("Treasury:", treasury);
        console.log("Centuari:", centuari);
    }

    /// @notice Deploy Treasury, grant TOKEN_MANAGER_ROLE to deployer, set supported tokens.
    function deploy() public returns (address treasury_) {
        Treasury treasury = new Treasury();
        treasury_ = address(treasury);

        treasury.grantRole(treasury.TOKEN_MANAGER_ROLE(), msg.sender);

        address[] memory tokens = SupportedTokens.getSupportedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            treasury.setSupportedToken(tokens[i], true);
        }

        return treasury_;
    }
}
