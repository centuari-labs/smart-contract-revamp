// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

/// @title DeployMockTokens
/// @notice Deploys all mock tokens for testnet use (USDC, USDT, IDRX, XSGD, BTC, ETH, XAUT, Ondo tokenized)
/// @dev Tokens are wired to Faucet and used across the platform for testnet testing
contract DeployMockTokens is Script {
    struct TokenConfig {
        string name;
        string symbol;
        uint8 decimals;
    }

    /// @notice Main deployment function; deploys all 11 mock tokens with initial supply to msg.sender
    function run() external {
        vm.startBroadcast();

        TokenConfig[11] memory configs = [
            TokenConfig("USD Coin", "USDC", 6),
            TokenConfig("Tether USD", "USDT", 6),
            TokenConfig("Indonesian Rupiah", "IDRX", 6),
            TokenConfig("StraitsX SGD", "XSGD", 6),
            TokenConfig("Bitcoin", "BTC", 8),
            TokenConfig("Ethereum", "ETH", 18),
            TokenConfig("Tether Gold", "XAUT", 6),
            TokenConfig("iShares Silver Trust (Ondo Tokenized)", "SLVon", 18),
            TokenConfig("NVIDIA (Ondo Tokenized)", "NVDAon", 18),
            TokenConfig("Apple (Ondo Tokenized)", "AAPLon", 18),
            TokenConfig("iShares 20+ Year Treasury Bond ETF (Ondo Tokenized)", "TLTon", 18)
        ];

        console.log("=== Mock Tokens Deployment ===");

        for (uint256 i = 0; i < configs.length; i++) {
            TokenConfig memory c = configs[i];
            uint256 initialSupply = 1_000_000 * (10 ** c.decimals);
            MockToken token = new MockToken(c.name, c.symbol, c.decimals, initialSupply);
            console.log(c.symbol, address(token));
        }

        vm.stopBroadcast();
    }
}
