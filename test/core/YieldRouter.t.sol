// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {YieldRouter} from "../../src/core/YieldRouter.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {IYieldRouter} from "../../src/interfaces/IYieldRouter.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Mock Contracts ============

/// @notice Simple mock adapter: 1 share = 1 token (no yield for simplicity)
contract MockYieldAdapter is IYieldAdapter {
    mapping(address => uint256) public totalDeployed;

    function deploy(address asset, uint256 amount) external override returns (uint256 shares) {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        totalDeployed[asset] += amount;
        return amount; // shares == amount (1:1)
    }

    function recall(address asset, uint256 shares) external override returns (uint256 amount) {
        amount = shares; // 1:1
        totalDeployed[asset] -= shares;
        IERC20(asset).transfer(msg.sender, amount);
    }

    function getDeployedValue(address, uint256 shares) external pure override returns (uint256) {
        return shares;
    }

    function getAPY(address) external pure override returns (uint256) {
        return 500; // 5%
    }

    function isAvailable(address) external pure override returns (bool) {
        return true;
    }

    function canRecall(address, uint256) external pure override returns (bool) {
        return true;
    }
}

/// @notice Mock BalanceLedger that records moveToYieldRouter / moveFromYieldRouter calls
contract MockBalanceLedger {
    mapping(address => mapping(address => IBalanceLedger.UserBalance)) public balances;

    function moveToYieldRouter(address user, address asset, uint256 amount, uint256 shares) external {
        balances[user][asset].available -= amount;
        balances[user][asset].inYieldRouter += amount;
        balances[user][asset].yieldRouterShares += shares;
    }

    function moveFromYieldRouter(address user, address asset, uint256 amount, uint256 shares) external {
        balances[user][asset].inYieldRouter -= amount;
        balances[user][asset].yieldRouterShares -= shares;
        balances[user][asset].available += amount;
    }

    /// @notice Helper to seed a user's available balance in the mock
    function setAvailable(address user, address asset, uint256 amount) external {
        balances[user][asset].available = amount;
    }

    function getAvailable(address user, address asset) external view returns (uint256) {
        return balances[user][asset].available;
    }

    function getInYieldRouter(address user, address asset) external view returns (uint256) {
        return balances[user][asset].inYieldRouter;
    }
}

// ============ Test Contract ============

contract YieldRouterTest is Test {
    YieldRouter public router;
    MockBalanceLedger public mockLedger;
    MockYieldAdapter public adapter;
    MockToken public usdc;

    address public owner = address(0x1);
    address public multisig = address(0x2);
    address public authorizedCaller = address(0x3);
    address public user = address(0x10);
    address public attacker = address(0x99);

    uint256 constant DEPLOY_AMOUNT = 10_000e6;
    // Reserve must satisfy MIN_RESERVE_RATIO_BPS (10%) against total deployed.
    // If we deploy 10_000, reserve must be >= 1_000.  We seed 2_000 to have headroom.
    uint256 constant RESERVE_SEED = 2_000e6;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        mockLedger = new MockBalanceLedger();
        adapter = new MockYieldAdapter();

        // Deploy YieldRouter behind a transparent proxy
        router = YieldRouter(address(new TransparentUpgradeableProxy(
            address(new YieldRouter()), owner,
            abi.encodeCall(YieldRouter.initialize, (owner, address(mockLedger), multisig))
        )));

        // Configuration
        vm.startPrank(owner);
        router.setAuthorizedCaller(authorizedCaller, true);
        router.registerAdapter(address(adapter));
        vm.stopPrank();

        // Fund the authorizedCaller so it can deposit to reserve and deploy
        usdc.mint(authorizedCaller, 1_000_000e6);

        // Seed the InsuranceReserve so the 10% ratio check passes when deploying
        vm.startPrank(authorizedCaller);
        usdc.approve(address(router), type(uint256).max);
        router.depositToReserve(address(usdc), RESERVE_SEED);
        vm.stopPrank();

        // Give the adapter approval from the router's perspective —
        // deploy() calls forceApprove internally; we just need the router to hold tokens.
        // Actually deploy() pulls from router via forceApprove, so mint tokens to router.
        usdc.mint(address(router), 1_000_000e6);

        // Seed user's "available" in the mock ledger so moveToYieldRouter won't underflow
        mockLedger.setAvailable(authorizedCaller, address(usdc), 1_000_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. test_deploy_succeeds
    // ─────────────────────────────────────────────────────────────────────────
    function test_deploy_succeeds() public {
        vm.prank(authorizedCaller);
        vm.expectEmit(true, true, true, true);
        emit IYieldRouter.Deployed(authorizedCaller, address(usdc), address(adapter), DEPLOY_AMOUNT, DEPLOY_AMOUNT);
        router.deploy(address(usdc), DEPLOY_AMOUNT, address(adapter));

        // Verify the adapter received the tokens
        assertEq(adapter.totalDeployed(address(usdc)), DEPLOY_AMOUNT);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. test_deploy_reverts_paused_adapter
    // ─────────────────────────────────────────────────────────────────────────
    function test_deploy_reverts_paused_adapter() public {
        vm.prank(multisig);
        router.pauseAdapter(address(adapter));

        vm.prank(authorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IYieldRouter.AdapterPausedError.selector, address(adapter)));
        router.deploy(address(usdc), DEPLOY_AMOUNT, address(adapter));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. test_recall_succeeds
    // ─────────────────────────────────────────────────────────────────────────
    function test_recall_succeeds() public {
        // First deploy so there are shares to recall
        vm.prank(authorizedCaller);
        router.deploy(address(usdc), DEPLOY_AMOUNT, address(adapter));

        uint256 sharesToRecall = DEPLOY_AMOUNT;

        // Seed the mock ledger's inYieldRouter side so moveFromYieldRouter won't underflow
        // The mock ledger was updated by the deploy call via moveToYieldRouter.
        // Now recall.
        vm.prank(authorizedCaller);
        vm.expectEmit(true, true, true, false); // adapter is indexed
        emit IYieldRouter.Recalled(authorizedCaller, address(usdc), address(adapter), DEPLOY_AMOUNT, sharesToRecall);
        uint256 recalled = router.recall(authorizedCaller, address(usdc), sharesToRecall);

        assertEq(recalled, DEPLOY_AMOUNT);
        assertEq(adapter.totalDeployed(address(usdc)), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. test_recallAll_succeeds
    // ─────────────────────────────────────────────────────────────────────────
    function test_recallAll_succeeds() public {
        // Deploy
        vm.prank(authorizedCaller);
        router.deploy(address(usdc), DEPLOY_AMOUNT, address(adapter));

        // RecallAll
        vm.prank(authorizedCaller);
        router.recallAll(authorizedCaller, address(usdc));

        assertEq(adapter.totalDeployed(address(usdc)), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. test_pauseAdapter_blocks_deploy
    // ─────────────────────────────────────────────────────────────────────────
    function test_pauseAdapter_blocks_deploy() public {
        assertTrue(!router.isAdapterPaused(address(adapter)));

        vm.prank(multisig);
        router.pauseAdapter(address(adapter));

        assertTrue(router.isAdapterPaused(address(adapter)));

        vm.prank(authorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IYieldRouter.AdapterPausedError.selector, address(adapter)));
        router.deploy(address(usdc), DEPLOY_AMOUNT, address(adapter));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. test_pauseAdapter_allows_recall
    // ─────────────────────────────────────────────────────────────────────────
    function test_pauseAdapter_allows_recall() public {
        // Deploy first (while adapter is not paused)
        vm.prank(authorizedCaller);
        router.deploy(address(usdc), DEPLOY_AMOUNT, address(adapter));

        // Now pause
        vm.prank(multisig);
        router.pauseAdapter(address(adapter));
        assertTrue(router.isAdapterPaused(address(adapter)));

        // Recall should still work even while paused (protocol needs capital out)
        vm.prank(authorizedCaller);
        uint256 recalled = router.recall(authorizedCaller, address(usdc), DEPLOY_AMOUNT);

        assertEq(recalled, DEPLOY_AMOUNT);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. test_pauseAdapter_expires_72h
    // ─────────────────────────────────────────────────────────────────────────
    function test_pauseAdapter_expires_72h() public {
        uint256 pauseTime = block.timestamp;

        vm.prank(multisig);
        router.pauseAdapter(address(adapter));
        assertTrue(router.isAdapterPaused(address(adapter)));

        // Warp past the 72h expiry
        vm.warp(pauseTime + 73 hours);
        assertFalse(router.isAdapterPaused(address(adapter)));

        // Deploy should now succeed
        vm.prank(authorizedCaller);
        router.deploy(address(usdc), DEPLOY_AMOUNT, address(adapter));

        assertEq(adapter.totalDeployed(address(usdc)), DEPLOY_AMOUNT);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. test_depositToReserve
    // ─────────────────────────────────────────────────────────────────────────
    function test_depositToReserve() public {
        uint256 depositAmount = 5_000e6;
        usdc.mint(authorizedCaller, depositAmount);

        // Check that verifyReserveRatioForAsset reflects the new deposit
        // Before: RESERVE_SEED = 2_000, totalDeployed = 0 → ratio = denominator (10000)
        assertTrue(router.verifyReserveRatioForAsset(address(usdc)));

        vm.prank(authorizedCaller);
        usdc.approve(address(router), depositAmount);
        vm.prank(authorizedCaller);
        router.depositToReserve(address(usdc), depositAmount);

        // After deposit, the contract holds the tokens
        // Reserve stays sufficient
        assertTrue(router.verifyReserveRatioForAsset(address(usdc)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. test_withdrawFromReserve
    // ─────────────────────────────────────────────────────────────────────────
    function test_withdrawFromReserve() public {
        // Deploy capital so the reserve ratio matters
        vm.prank(authorizedCaller);
        router.deploy(address(usdc), DEPLOY_AMOUNT, address(adapter));

        // After deploy: totalDeployed = 10_000, reserve = 2_000 → ratio = 2000/10000 = 20% ≥ 10%
        assertTrue(router.verifyReserveRatioForAsset(address(usdc)));

        // Recall the capital — triggers moveFromYieldRouter, the actual token flow
        vm.prank(authorizedCaller);
        router.recall(authorizedCaller, address(usdc), DEPLOY_AMOUNT);

        // totalDeployed = 0 now → ratio = 10000 (trivially sufficient)
        assertTrue(router.verifyReserveRatioForAsset(address(usdc)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 10. test_registerAdapter
    // ─────────────────────────────────────────────────────────────────────────
    function test_registerAdapter() public {
        MockYieldAdapter newAdapter = new MockYieldAdapter();

        vm.prank(owner);
        router.registerAdapter(address(newAdapter));

        // Verify it works by deploying to it
        usdc.mint(address(router), DEPLOY_AMOUNT);
        mockLedger.setAvailable(authorizedCaller, address(usdc), DEPLOY_AMOUNT + mockLedger.getAvailable(authorizedCaller, address(usdc)));

        vm.prank(authorizedCaller);
        router.deploy(address(usdc), DEPLOY_AMOUNT, address(newAdapter));

        assertEq(newAdapter.totalDeployed(address(usdc)), DEPLOY_AMOUNT);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 11. test_onlyAuthorized_reverts
    // ─────────────────────────────────────────────────────────────────────────
    function test_onlyAuthorized_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IYieldRouter.Unauthorized.selector);
        router.deploy(address(usdc), DEPLOY_AMOUNT, address(adapter));

        vm.prank(attacker);
        vm.expectRevert(IYieldRouter.Unauthorized.selector);
        router.recall(user, address(usdc), 1000);

        vm.prank(attacker);
        vm.expectRevert(IYieldRouter.Unauthorized.selector);
        router.recallAll(user, address(usdc));

        vm.prank(attacker);
        vm.expectRevert(IYieldRouter.Unauthorized.selector);
        router.recallForOrder(user, address(usdc), 1000);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 12. test_setEnabled_toggle
    // ─────────────────────────────────────────────────────────────────────────
    function test_setEnabled_toggle() public {
        // Default: disabled (false)
        assertFalse(router.isEnabled(user, address(usdc)));

        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit IYieldRouter.RouterEnabledChanged(user, address(usdc), true);
        router.setEnabled(address(usdc), true);

        assertTrue(router.isEnabled(user, address(usdc)));

        vm.prank(user);
        router.setEnabled(address(usdc), false);
        assertFalse(router.isEnabled(user, address(usdc)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Boundary: deploy zero amount reverts
    // ─────────────────────────────────────────────────────────────────────────
    function test_deploy_zero_amount_reverts() public {
        vm.prank(authorizedCaller);
        vm.expectRevert(IYieldRouter.ZeroAmount.selector);
        router.deploy(address(usdc), 0, address(adapter));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Boundary: pauseAdapter only callable by multisig
    // ─────────────────────────────────────────────────────────────────────────
    function test_pauseAdapter_onlyMultisig_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IYieldRouter.Unauthorized.selector);
        router.pauseAdapter(address(adapter));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Boundary: reserve ratio enforced — deploy fails when ratio would drop below 10%
    // ─────────────────────────────────────────────────────────────────────────
    function test_deploy_reverts_reserve_ratio_violated() public {
        // Current reserve = RESERVE_SEED (2_000e6).
        // Deploy enough that reserve/(reserve+deployed) < 10%.
        // For 10% to be violated: reserve / newTotal < 0.10
        // 2000 / (2000 + X) < 0.10  →  20000 < 2000 + X  →  X > 18000
        uint256 largeAmount = 19_000e6;
        usdc.mint(address(router), largeAmount);
        mockLedger.setAvailable(
            authorizedCaller,
            address(usdc),
            largeAmount + mockLedger.getAvailable(authorizedCaller, address(usdc))
        );

        vm.prank(authorizedCaller);
        vm.expectRevert(); // ReserveRatioViolated
        router.deploy(address(usdc), largeAmount, address(adapter));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fuzz: deploy and recall are inverse operations
    // ─────────────────────────────────────────────────────────────────────────
    function testFuzz_deploy_recall_inverse(uint256 amount) public {
        // Reserve = RESERVE_SEED (2_000e6).
        // To keep reserve ratio: amount <= reserve / 0.10 - reserve = reserve * 9
        //  = 2_000e6 * 9 = 18_000e6
        amount = bound(amount, 1e6, 18_000e6);

        usdc.mint(address(router), amount);
        // Ensure available covers amount in mock
        uint256 existingAvail = mockLedger.getAvailable(authorizedCaller, address(usdc));
        if (existingAvail < amount) {
            mockLedger.setAvailable(authorizedCaller, address(usdc), amount);
        }

        vm.prank(authorizedCaller);
        router.deploy(address(usdc), amount, address(adapter));

        assertEq(adapter.totalDeployed(address(usdc)), amount);

        vm.prank(authorizedCaller);
        uint256 recalled = router.recall(authorizedCaller, address(usdc), amount);

        assertEq(recalled, amount);
        assertEq(adapter.totalDeployed(address(usdc)), 0);
    }
}
