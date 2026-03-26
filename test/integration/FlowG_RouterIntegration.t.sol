// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CentuariRouter} from "../../src/core/CentuariRouter.sol";
import {ICentuariRouter} from "../../src/interfaces/ICentuariRouter.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title FlowG_RouterIntegration
/// @notice Integration test: external protocol submits lend intent, engine fills via onIntentFilled
contract FlowG_RouterIntegrationTest is Test {
    CentuariRouter public router;
    MockToken public usdc;
    MockToken public cbt; // Mock CBT for fill delivery

    address owner = address(0x1);
    address endpoint = address(0xE0);
    address user = address(0x10);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        cbt = new MockToken("Mock CBT", "mCBT", 6, 0);

        vm.warp(100000);

        router = CentuariRouter(address(new TransparentUpgradeableProxy(
            address(new CentuariRouter()), owner,
            abi.encodeCall(CentuariRouter.initialize, (owner, endpoint))
        )));

        // Fund user
        usdc.mint(user, 50_000e6);
        // Fund router with CBT for delivery
        cbt.mint(address(router), 50_000e6);
    }

    /// @notice User submits lend intent -> engine fills -> CBT delivered
    function test_flowG_submit_and_fill() public {
        uint256 amount = 5_000e6;
        uint256 deadline = block.timestamp + 1 hours;

        // User submits intent
        vm.startPrank(user);
        usdc.approve(address(router), amount);
        bytes32 intentId = router.submitLendIntent(
            address(usdc), amount, 500, 0, deadline, address(0)
        );
        vm.stopPrank();

        // Verify intent stored
        (ICentuariRouter.IntentState state,) = router.getIntentStatus(intentId);
        assertEq(uint8(state), uint8(ICentuariRouter.IntentState.PENDING));

        // Router holds USDC
        assertEq(usdc.balanceOf(address(router)), amount);

        // Engine fills intent — callback to EOA user will fail (no onIntentFilled function)
        // so the state becomes CALLBACK_FAILED and CBT is held for manual claim
        uint256 cbtAmount = 5_050e6;
        cbt.mint(address(router), cbtAmount);

        vm.prank(endpoint);
        router.onIntentFilled(intentId, address(cbt), cbtAmount, amount, 500);

        // Verify CALLBACK_FAILED (EOA user has no callback handler)
        (state,) = router.getIntentStatus(intentId);
        assertEq(uint8(state), uint8(ICentuariRouter.IntentState.CALLBACK_FAILED));

        // User claims via claimUndeliveredCBT
        vm.prank(user);
        router.claimUndeliveredCBT(intentId);
        assertEq(cbt.balanceOf(user), cbtAmount, "User received CBT via claim");
    }

    /// @notice Non-endpoint cannot call onIntentFilled (Invariant #12)
    function test_flowG_non_endpoint_reverts() public {
        vm.startPrank(user);
        usdc.approve(address(router), 1000e6);
        bytes32 intentId = router.submitLendIntent(
            address(usdc), 1000e6, 500, 0, block.timestamp + 1 hours, address(0)
        );
        vm.stopPrank();

        vm.prank(user); // Not endpoint
        vm.expectRevert(ICentuariRouter.Unauthorized.selector);
        router.onIntentFilled(intentId, address(cbt), 1050e6, 1000e6, 500);
    }

    /// @notice Cancel returns tokens to user
    function test_flowG_cancel_returns_tokens() public {
        uint256 amount = 3_000e6;
        vm.startPrank(user);
        usdc.approve(address(router), amount);
        bytes32 intentId = router.submitLendIntent(
            address(usdc), amount, 500, 0, block.timestamp + 1 hours, address(0)
        );

        uint256 balBefore = usdc.balanceOf(user);
        router.cancelIntent(intentId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), balBefore + amount, "Tokens returned on cancel");
    }
}
