// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CentuariRouter} from "../../src/core/CentuariRouter.sol";
import {ICentuariRouter} from "../../src/interfaces/ICentuariRouter.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal mock that reverts on onIntentFilled — used to trigger CALLBACK_FAILED state
contract RevertingCallback {
    fallback() external {
        revert("callback revert");
    }
}

/// @dev Minimal mock CBT that the router can safeTransfer
contract MockCBT is MockToken {
    constructor() MockToken("Mock CBT", "mCBT", 6, 0) {}
}

/// @dev Mock that successfully implements onIntentFilled (no-op)
contract MockSuccessCallback {
    function onIntentFilled(bytes32, address, uint256, uint256, uint256) external {}
}

contract CentuariRouterTest is Test {
    CentuariRouter public router;
    MockToken public usdc;
    MockCBT public cbt;
    MockSuccessCallback public successCallback;

    address public owner = address(0x1);
    address public endpoint = address(0x2);
    address public user = address(0x10);
    address public other = address(0x20);

    uint256 public constant AMOUNT = 1000e6; // $1000 USDC
    uint256 public constant MIN_RATE_BPS = 500;
    uint256 public constant MATURITY_HINT = 0;

    function setUp() public {
        // Deploy mock tokens and callback
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        cbt = new MockCBT();
        successCallback = new MockSuccessCallback();

        // Deploy CentuariRouter behind proxy
        router = CentuariRouter(
            address(
                new TransparentUpgradeableProxy(
                    address(new CentuariRouter()),
                    owner,
                    abi.encodeCall(CentuariRouter.initialize, (owner, endpoint))
                )
            )
        );

        // Fund user with USDC
        usdc.mint(user, 10_000e6);
        // Fund router with CBT so it can deliver on onIntentFilled
        cbt.mint(address(router), 10_000e6);

        vm.label(address(router), "CentuariRouter");
        vm.label(address(usdc), "USDC");
        vm.label(address(cbt), "CBT");
        vm.label(user, "user");
        vm.label(endpoint, "endpoint");
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _deadline() internal view returns (uint256) {
        // 5 minutes (MIN_DEADLINE_OFFSET) + 1 second buffer
        return block.timestamp + 5 minutes + 1;
    }

    function _submitLendIntent(address caller, uint256 amount) internal returns (bytes32 intentId) {
        vm.startPrank(caller);
        IERC20(address(usdc)).approve(address(router), amount);
        intentId = router.submitLendIntent(address(usdc), amount, MIN_RATE_BPS, MATURITY_HINT, _deadline(), address(successCallback));
        vm.stopPrank();
    }

    // ── Test: submitLendIntent transfers tokens ───────────────────────────────

    function test_submitLendIntent_transfers_tokens() public {
        uint256 userBefore = usdc.balanceOf(user);
        uint256 routerBefore = usdc.balanceOf(address(router));

        _submitLendIntent(user, AMOUNT);

        assertEq(usdc.balanceOf(user), userBefore - AMOUNT);
        assertEq(usdc.balanceOf(address(router)), routerBefore + AMOUNT);
    }

    // ── Test: submitLendIntent emits LendIntentSubmitted event ────────────────

    function test_submitLendIntent_emits_event() public {
        uint256 deadline = _deadline();

        vm.startPrank(user);
        usdc.approve(address(router), AMOUNT);

        vm.expectEmit(false, true, true, true);
        emit ICentuariRouter.LendIntentSubmitted(
            bytes32(0), // intentId — we match on indexed submitter instead
            user,
            address(usdc),
            AMOUNT,
            MIN_RATE_BPS,
            MATURITY_HINT,
            deadline
        );
        router.submitLendIntent(address(usdc), AMOUNT, MIN_RATE_BPS, MATURITY_HINT, deadline, address(0));
        vm.stopPrank();
    }

    // ── Test: submitLendIntent stores PENDING intent ──────────────────────────

    function test_submitLendIntent_stores_details() public {
        bytes32 intentId = _submitLendIntent(user, AMOUNT);

        (ICentuariRouter.IntentState state, ICentuariRouter.IntentDetails memory details) =
            router.getIntentStatus(intentId);

        assertEq(uint8(state), uint8(ICentuariRouter.IntentState.PENDING));
        assertEq(details.submitter, user);
        assertEq(details.asset, address(usdc));
        assertEq(details.totalAmount, AMOUNT);
        assertEq(details.filledAmount, 0);
        assertFalse(details.isBorrow);
    }

    // ── Test: submitBorrowIntent stores intent ────────────────────────────────

    function test_submitBorrowIntent_stores_details() public {
        vm.prank(user);
        bytes32 intentId = router.submitBorrowIntent(
            address(usdc), AMOUNT, MIN_RATE_BPS, MATURITY_HINT, _deadline(), address(0)
        );

        (ICentuariRouter.IntentState state, ICentuariRouter.IntentDetails memory details) =
            router.getIntentStatus(intentId);

        assertEq(uint8(state), uint8(ICentuariRouter.IntentState.PENDING));
        assertEq(details.submitter, user);
        assertEq(details.totalAmount, AMOUNT);
        assertTrue(details.isBorrow);
        // Borrow intents do NOT transfer tokens — router balance unchanged
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    // ── Test: cancelIntent returns tokens to submitter ────────────────────────

    function test_cancelIntent_returns_tokens() public {
        bytes32 intentId = _submitLendIntent(user, AMOUNT);

        uint256 userBefore = usdc.balanceOf(user);

        vm.prank(user);
        router.cancelIntent(intentId);

        assertEq(usdc.balanceOf(user), userBefore + AMOUNT);

        (ICentuariRouter.IntentState state,) = router.getIntentStatus(intentId);
        assertEq(uint8(state), uint8(ICentuariRouter.IntentState.CANCELLED));
    }

    // ── Test: cancelIntent only submitter ─────────────────────────────────────

    function test_cancelIntent_only_submitter_reverts() public {
        bytes32 intentId = _submitLendIntent(user, AMOUNT);

        vm.prank(other);
        vm.expectRevert(ICentuariRouter.Unauthorized.selector);
        router.cancelIntent(intentId);
    }

    // ── Test: onIntentFilled by endpoint succeeds ─────────────────────────────

    function test_onIntentFilled_by_endpoint() public {
        bytes32 intentId = _submitLendIntent(user, AMOUNT);

        uint256 cbtAmount = 1050e6;
        // Mint CBT to router so it can transfer on fill
        cbt.mint(address(router), cbtAmount);

        vm.prank(endpoint);
        router.onIntentFilled(intentId, address(cbt), cbtAmount, AMOUNT, MIN_RATE_BPS);

        (ICentuariRouter.IntentState state, ICentuariRouter.IntentDetails memory details) =
            router.getIntentStatus(intentId);

        assertEq(uint8(state), uint8(ICentuariRouter.IntentState.FILLED));
        assertEq(details.filledAmount, AMOUNT);
        assertEq(details.cbtAmount, cbtAmount);
    }

    // ── Test: onIntentFilled by non-endpoint reverts ──────────────────────────

    function test_onIntentFilled_by_non_endpoint_reverts() public {
        bytes32 intentId = _submitLendIntent(user, AMOUNT);

        vm.prank(other);
        vm.expectRevert(ICentuariRouter.Unauthorized.selector);
        router.onIntentFilled(intentId, address(cbt), 1050e6, AMOUNT, MIN_RATE_BPS);
    }

    // ── Test: onIntentFilled partial fill → PARTIAL state ────────────────────

    function test_onIntentFilled_partial_fill() public {
        bytes32 intentId = _submitLendIntent(user, AMOUNT);

        uint256 partialFill = AMOUNT / 2;
        uint256 cbtAmount = 525e6;
        cbt.mint(address(router), cbtAmount);

        vm.prank(endpoint);
        router.onIntentFilled(intentId, address(cbt), cbtAmount, partialFill, MIN_RATE_BPS);

        (ICentuariRouter.IntentState state, ICentuariRouter.IntentDetails memory details) =
            router.getIntentStatus(intentId);

        assertEq(uint8(state), uint8(ICentuariRouter.IntentState.PARTIAL));
        assertEq(details.filledAmount, partialFill);
        assertEq(details.unfilledAmount, AMOUNT - partialFill);
    }

    // ── Test: claimUndeliveredCBT recovers from CALLBACK_FAILED ──────────────

    function test_claimUndeliveredCBT() public {
        // Submit a lend intent with a reverting callback target
        RevertingCallback badCallback = new RevertingCallback();

        vm.startPrank(user);
        usdc.approve(address(router), AMOUNT);
        bytes32 intentId = router.submitLendIntent(
            address(usdc), AMOUNT, MIN_RATE_BPS, MATURITY_HINT, _deadline(), address(badCallback)
        );
        vm.stopPrank();

        uint256 cbtAmount = 1050e6;
        cbt.mint(address(router), cbtAmount);

        // Endpoint triggers fill — callback will revert, CBT stays in router
        vm.prank(endpoint);
        router.onIntentFilled(intentId, address(cbt), cbtAmount, AMOUNT, MIN_RATE_BPS);

        (ICentuariRouter.IntentState state,) = router.getIntentStatus(intentId);
        assertEq(uint8(state), uint8(ICentuariRouter.IntentState.CALLBACK_FAILED));

        // User claims the undelivered CBT
        uint256 userCbtBefore = cbt.balanceOf(user);
        vm.prank(user);
        router.claimUndeliveredCBT(intentId);

        assertEq(cbt.balanceOf(user), userCbtBefore + cbtAmount);
    }

    // ── Test: ERC-4626 deposit requires vault asset ────────────────────────────

    function test_erc4626_deposit_no_vault_asset_reverts() public {
        // Vault asset not set → reverts
        vm.expectRevert(bytes("CentuariRouter: vault asset not set"));
        router.deposit(AMOUNT, user);
    }

    // ── Test: ERC-4626 withdraw with zero shares reverts ────────────────────────

    function test_erc4626_withdraw_zero_reverts() public {
        vm.expectRevert(bytes("CentuariRouter: zero withdraw"));
        router.withdraw(0, user, user);
    }
}
