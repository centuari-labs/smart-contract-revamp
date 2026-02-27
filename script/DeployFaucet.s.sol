// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockToken} from "../src/mocks/MockToken.sol";
import {Faucet} from "../src/mocks/Faucet.sol";

/// @notice Minimal interface for AccessControl-like tokens that support grantRole.
interface IAccessControlLike {
    function grantRole(bytes32 role, address account) external;
}

contract DeployFaucet is Script {
    /// @dev Role hash used by MockToken for minters.
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Deploys Faucet and optionally wires it to tokens from FAUCET_TOKENS env (comma-separated addresses).
    function run() external {
        address operatorAddress = vm.envAddress("BACKEND_OPERATOR");

        vm.startBroadcast();

        Faucet faucet = new Faucet(operatorAddress);
        console.log("Faucet", address(faucet));
        console.log("Operator", operatorAddress);

        // Best-effort wiring of tokens specified in FAUCET_TOKENS (comma-separated addresses).
        // Any failures to read env, grant roles, or read decimals are logged and skipped
        // so that the script does not revert.
        try vm.envAddress("FAUCET_TOKENS", ",") returns (
            address[] memory tokenAddresses
        ) {
            for (uint256 i = 0; i < tokenAddresses.length; i++) {
                address tokenAddr = tokenAddresses[i];

                // Never attempt to treat the faucet itself as a token.
                if (tokenAddr == address(faucet)) {
                    console.log(
                        "Skipping faucet address in FAUCET_TOKENS:",
                        tokenAddr
                    );
                    continue;
                }

                // Best-effort: some tokens may not implement AccessControl / MINTER_ROLE.
                // Use a generic interface and fixed MINTER_ROLE hash so that failures
                // (including missing grantRole) can be caught without reverting the script.
                IAccessControlLike accessToken = IAccessControlLike(tokenAddr);
                try accessToken.grantRole(MINTER_ROLE, address(faucet)) {
                    console.log(
                        "Granted MINTER_ROLE to Faucet for",
                        tokenAddr
                    );
                } catch {
                    console.log(
                        "Skipping grantRole (no MINTER_ROLE / AccessControl) for",
                        tokenAddr
                    );
                }

                // Default to 18 decimals; try to read actual decimals when available.
                uint8 decimals = 18;
                try MockToken(tokenAddr).decimals() returns (uint8 d) {
                    decimals = d;
                } catch {
                    console.log(
                        "Skipping decimals() lookup for",
                        tokenAddr
                    );
                }

                uint256 maxPerRequest = 10_000 * (10 ** decimals);
                faucet.addToken(tokenAddr, maxPerRequest, 0);
                console.log("Wired token", tokenAddr);
            }
        } catch {
            // If FAUCET_TOKENS is not set or cannot be parsed, just deploy the faucet.
            console.log("No FAUCET_TOKENS found or parse failed; skipping wiring.");
        }
        vm.stopBroadcast();
}
}