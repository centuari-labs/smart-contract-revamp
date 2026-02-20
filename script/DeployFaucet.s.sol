// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockToken} from "../src/mocks/MockToken.sol";
import {Faucet} from "../src/mocks/Faucet.sol";

/// @title DeployFaucet
/// @notice Deploys Faucet and optionally wires it to existing mock tokens (grant minter role, addToken).
/// @dev Set FAUCET_OPERATOR env var to the backend address; otherwise msg.sender is used as operator.
///      Optionally set FAUCET_TOKENS to comma-separated token addresses (e.g. FAUCET_TOKENS=0x1,0x2) to grant minter and addToken for each; broadcaster must be token admin.
contract DeployFaucet is Script {
    /// @notice Deploys Faucet and optionally wires it to tokens from FAUCET_TOKENS env (comma-separated addresses).
    function run() external {
        address operatorAddress = _getOperator();

        vm.startBroadcast();

        Faucet faucet = new Faucet(operatorAddress);
        console.log("Faucet", address(faucet));
        console.log("Operator", operatorAddress);

        try vm.envAddress("FAUCET_TOKENS", ",") returns (
            address[] memory tokenAddresses
        ) {
            for (uint256 i = 0; i < tokenAddresses.length; i++) {
                address tokenAddr = tokenAddresses[i];
                MockToken token = MockToken(tokenAddr);
                token.grantRole(token.MINTER_ROLE(), address(faucet));
                uint8 decimals = token.decimals();
                uint256 maxPerRequest = 10_000 * (10 ** decimals);
                faucet.addToken(tokenAddr, maxPerRequest, 0);
                console.log("Wired token", tokenAddr);
            }
        } catch {}
        vm.stopBroadcast();
    }

    function _getOperator() internal view returns (address) {
        try vm.envAddress("FAUCET_OPERATOR") returns (address a) {
            return a;
        } catch {
            return msg.sender;
        }
    }
}
