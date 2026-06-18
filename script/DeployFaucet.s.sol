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

    /// @dev Default drip amount (human-readable) when a token symbol is not in the map.
    uint256 internal constant DEFAULT_DRIP_AMOUNT = 10_000;

    /// @notice Returns the human-readable drip amount for a given token symbol.
    ///         These values must match the frontend DRIP_AMOUNTS in faucet-token-grid.tsx.
    function _dripAmountFor(string memory symbol) internal pure returns (uint256) {
        bytes32 s = keccak256(bytes(symbol));
        if (s == keccak256("USDC")) return 5_000;
        if (s == keccak256("USDT")) return 5_000;
        if (s == keccak256("IDRX")) return 10_000_000;
        if (s == keccak256("XSGD")) return 7_000;
        if (s == keccak256("BTC")) return 1;
        if (s == keccak256("ETH")) return 5;
        if (s == keccak256("XAUT")) return 5;
        if (s == keccak256("NVDAon")) return 100;
        if (s == keccak256("AAPLon")) return 100;
        if (s == keccak256("SLVon")) return 100;
        if (s == keccak256("TLTon")) return 100;
        return DEFAULT_DRIP_AMOUNT;
    }

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
        try vm.envAddress("FAUCET_TOKENS", ",") returns (address[] memory tokenAddresses) {
            for (uint256 i = 0; i < tokenAddresses.length; i++) {
                address tokenAddr = tokenAddresses[i];

                // Never attempt to treat the faucet itself as a token.
                if (tokenAddr == address(faucet)) {
                    console.log("Skipping faucet address in FAUCET_TOKENS:", tokenAddr);
                    continue;
                }

                // Best-effort: some tokens may not implement AccessControl / MINTER_ROLE.
                // Use a generic interface and fixed MINTER_ROLE hash so that failures
                // (including missing grantRole) can be caught without reverting the script.
                IAccessControlLike accessToken = IAccessControlLike(tokenAddr);
                try accessToken.grantRole(MINTER_ROLE, address(faucet)) {
                    console.log("Granted MINTER_ROLE to Faucet for", tokenAddr);
                } catch {
                    console.log("Skipping grantRole (no MINTER_ROLE / AccessControl) for", tokenAddr);
                }

                // Default to 18 decimals; try to read actual decimals when available.
                uint8 decimals = 18;
                try MockToken(tokenAddr).decimals() returns (uint8 d) {
                    decimals = d;
                } catch {
                    console.log("Skipping decimals() lookup for", tokenAddr);
                }

                // Read token symbol to determine the correct drip amount.
                string memory symbol = "";
                try MockToken(tokenAddr).symbol() returns (string memory s) {
                    symbol = s;
                } catch {
                    console.log("Skipping symbol() lookup for", tokenAddr);
                }

                uint256 maxPerRequest = _dripAmountFor(symbol) * (10 ** decimals);
                faucet.addToken(tokenAddr, maxPerRequest, 0);
                console.log("Wired token", tokenAddr, "maxPerRequest", maxPerRequest);
            }
        } catch {
            // If FAUCET_TOKENS is not set or cannot be parsed, just deploy the faucet.
            console.log("No FAUCET_TOKENS found or parse failed; skipping wiring.");
        }
        vm.stopBroadcast();
    }
}
