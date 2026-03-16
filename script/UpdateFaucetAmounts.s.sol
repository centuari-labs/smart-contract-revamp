// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockToken} from "../src/mocks/MockToken.sol";
import {Faucet} from "../src/mocks/Faucet.sol";

/// @title UpdateFaucetAmounts
/// @notice Updates maxPerRequest for each token on an already-deployed Faucet contract
///         to match the frontend DRIP_AMOUNTS (faucet-token-grid.tsx).
/// @dev Requires FAUCET_ADDRESS and FAUCET_TOKENS env vars. Must be run by the Faucet owner.
contract UpdateFaucetAmounts is Script {
    /// @notice Returns the human-readable drip amount for a given token symbol.
    ///         Must stay in sync with DeployFaucet._dripAmountFor and frontend DRIP_AMOUNTS.
    function _dripAmountFor(
        string memory symbol
    ) internal pure returns (uint256) {
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
        return 10_000; // fallback
    }

    function run() external {
        address faucetAddress = vm.envAddress("FAUCET_ADDRESS");
        Faucet faucet = Faucet(faucetAddress);

        address[] memory tokenAddresses = vm.envAddress("FAUCET_TOKENS", ",");

        vm.startBroadcast();

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            address tokenAddr = tokenAddresses[i];

            // Skip the faucet address itself if accidentally included.
            if (tokenAddr == faucetAddress) continue;

            uint8 decimals = 18;
            try MockToken(tokenAddr).decimals() returns (uint8 d) {
                decimals = d;
            } catch {
                console.log("Cannot read decimals for", tokenAddr);
                continue;
            }

            string memory symbol = "";
            try MockToken(tokenAddr).symbol() returns (string memory s) {
                symbol = s;
            } catch {
                console.log("Cannot read symbol for", tokenAddr);
                continue;
            }

            uint256 newMaxPerRequest = _dripAmountFor(symbol) *
                (10 ** decimals);

            faucet.setTokenConfig(tokenAddr, newMaxPerRequest, 0);
            console.log("Updated", symbol, "maxPerRequest", newMaxPerRequest);
        }

        vm.stopBroadcast();
    }
}
