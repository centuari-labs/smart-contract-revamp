// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockCircleCCTP
/// @notice Simplified Circle CCTP (Cross-Chain Transfer Protocol) mock
/// @dev Simulates USDC burn-and-mint without actual cross-chain. Native USDC path.
contract MockCircleCCTP {
    using SafeERC20 for IERC20;

    struct BurnMessage {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        uint64 nonce;
        bool completed;
    }

    BurnMessage[] public burns;
    uint64 public nonceCounter;

    /// @notice Domain mapping (for reference in tests)
    /// @dev Ethereum=0, Avalanche=1, Optimism=2, Arbitrum=3, Base=6
    mapping(uint32 => string) public domainNames;

    constructor() {
        domainNames[0] = "Ethereum";
        domainNames[3] = "Arbitrum";
        domainNames[6] = "Base";
    }

    /// @notice Burn tokens for cross-chain transfer
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce) {
        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), amount);

        nonce = ++nonceCounter;
        burns.push(BurnMessage({
            amount: amount,
            destinationDomain: destinationDomain,
            mintRecipient: mintRecipient,
            burnToken: burnToken,
            nonce: nonce,
            completed: false
        }));
    }

    /// @notice Complete a burn (simulate attestation + mint on destination)
    /// @dev In tests, call this to "deliver" the CCTP transfer
    function completeBurn(uint256 burnIndex, address destinationToken) external {
        require(burnIndex < burns.length, "MockCCTP: invalid index");
        BurnMessage storage burn = burns[burnIndex];
        require(!burn.completed, "MockCCTP: already completed");

        burn.completed = true;

        address recipient = address(uint160(uint256(burn.mintRecipient)));
        IERC20(destinationToken).safeTransfer(recipient, burn.amount);
    }

    /// @notice Get number of pending burns
    function burnCount() external view returns (uint256) {
        return burns.length;
    }
}
