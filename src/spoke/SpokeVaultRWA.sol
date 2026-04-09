// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ISpokeVaultRWA} from "../interfaces/ISpokeVaultRWA.sol";
import {ILayerZeroEndpointV2} from "../interfaces/ILayerZeroEndpointV2.sol";

/// @title SpokeVaultRWA
/// @notice Spoke chain vault for compliance-restricted RWA tokens
/// @dev Locks RWAs permanently while position active. Sends attestation to hub.
///      Security Invariant #3: releaseLiquidation only via LayerZero from hub.
contract SpokeVaultRWA is ISpokeVaultRWA, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    mapping(address => mapping(address => uint256)) public lockedBalances; // user => asset => amount
    mapping(address => bool) public frozenAssets;

    /// @notice LayerZero endpoint (for receiving hub messages)
    address public layerZeroEndpoint;

    /// @notice Hub LiquidationEngine address (for source verification)
    address public hubLiquidationEngine;

    uint256 public attestationNonce;

    constructor(address owner_) Ownable(owner_) {}

    modifier onlyLayerZeroFromHub() {
        if (msg.sender != layerZeroEndpoint) revert OnlyLayerZeroFromHub();
        _;
    }

    /// @inheritdoc ISpokeVaultRWA
    function deposit(address asset, uint256 amount) external payable override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (frozenAssets[asset]) revert AssetFrozen(asset);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        lockedBalances[msg.sender][asset] += amount;

        // Construct attestation ID
        bytes32 attestationId = keccak256(abi.encode(msg.sender, asset, amount, ++attestationNonce));

        // B2 FIX: Send attestation to hub CollateralRegistry via LayerZero V2.
        // The hub's CollateralRegistry.processAttestation() validates and credits collateral.
        if (layerZeroEndpoint != address(0) && hubChainEid != 0) {
            bytes memory payload = abi.encode(attestationId, msg.sender, asset, amount, block.timestamp, block.chainid);
            ILayerZeroEndpointV2.MessagingParams memory params = ILayerZeroEndpointV2.MessagingParams({
                dstEid: hubChainEid,
                receiver: bytes32(uint256(uint160(hubCollateralRegistry))), // P1-4 FIX: send to CollateralRegistry, not LiquidationEngine
                message: payload,
                options: bytes(""),
                payInLzToken: false
            });
            ILayerZeroEndpointV2(layerZeroEndpoint).send{value: msg.value}(params, msg.sender);
        }

        emit RWADeposited(msg.sender, asset, amount);
        emit AttestationSent(msg.sender, asset, amount, attestationId);
    }

    /// @notice NC-02 FIX: releaseLiquidation is now internal — only callable via lzReceive().
    /// @dev The external function was vulnerable: onlyLayerZeroFromHub only checked msg.sender
    ///      but could NOT verify srcEid or sender (those are lzReceive params, not available here).
    ///      Now all liquidation releases go through lzReceive() which has full verification.
    function _releaseLiquidation(
        address user,
        address asset,
        uint256 amount,
        address liquidator
    ) internal {
        if (lockedBalances[user][asset] < amount) revert ZeroAmount();

        lockedBalances[user][asset] -= amount;
        IERC20(asset).safeTransfer(liquidator, amount);

        emit LiquidationReleased(user, asset, amount, liquidator);
    }

    /// @inheritdoc ISpokeVaultRWA
    function reportFrozen(address asset) external override onlyOwner {
        frozenAssets[asset] = true;
        emit AssetFrozenReported(asset);
    }

    // ============ Admin ============

    function setLayerZeroEndpoint(address ep) external onlyOwner { layerZeroEndpoint = ep; }
    function setHubLiquidationEngine(address hub) external onlyOwner { hubLiquidationEngine = hub; }
    function setHubCollateralRegistry(address registry) external onlyOwner { hubCollateralRegistry = registry; }

    /// @notice P1-4: Hub CollateralRegistry address for attestation delivery
    address public hubCollateralRegistry;

    /// @notice Hub chain EID for source verification
    uint32 public hubChainEid;

    function setHubChainEid(uint32 eid) external onlyOwner { hubChainEid = eid; }

    /// @notice LayerZero receive handler
    /// C-08 FIX: Verify sender == hubLiquidationEngine AND source chain == hubChainEid.
    /// Without this, any LayerZero message from any chain could drain all locked RWAs.
    function lzReceive(uint32 srcEid, bytes32 sender, bytes calldata message) external {
        require(msg.sender == layerZeroEndpoint, "SpokeVaultRWA: only LZ");
        require(srcEid == hubChainEid, "SpokeVaultRWA: invalid source chain");
        require(
            sender == bytes32(uint256(uint160(hubLiquidationEngine))),
            "SpokeVaultRWA: invalid hub sender"
        );

        (address user, address asset, uint256 amount, address liquidator) = abi.decode(
            message, (address, address, uint256, address)
        );
        _releaseLiquidation(user, asset, amount, liquidator);
    }
}
