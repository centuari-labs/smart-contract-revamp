// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {HubDepositor} from "../../src/core/cross-chain/HubDepositor.sol";
import {WithdrawalRegistry} from "../../src/core/cross-chain/WithdrawalRegistry.sol";
import {IWithdrawalRegistry} from "../../src/interfaces/cross-chain/IWithdrawalRegistry.sol";
import {CollateralManager} from "../../src/core/collateral/CollateralManager.sol";
import {ICollateralManager} from "../../src/interfaces/ICollateralManager.sol";
import {RiskModule} from "../../src/core/risk/RiskModule.sol";
import {OracleRouter} from "../../src/core/oracle/OracleRouter.sol";
import {PushOracle} from "../../src/core/oracle/PushOracle.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

/// @notice Controllable debt source — only the selector RiskModule reads.
contract MockCentuariDebt {
    mapping(address => address[]) internal _tokens;
    mapping(address => uint256[]) internal _amounts;

    function setDebts(address user, address[] calldata tokens, uint256[] calldata amounts) external {
        _tokens[user] = tokens;
        _amounts[user] = amounts;
    }

    function getBorrowerDebts(address user) external view returns (address[] memory, uint256[] memory) {
        return (_tokens[user], _amounts[user]);
    }
}

/// @title RiskModuleIntegration
/// @notice Proves the real RiskModule is interface-stable: the unchanged
///         WithdrawalRegistry + CollateralManager call `IRiskModule` and now
///         enforce REAL health-factor gates end-to-end, including the
///         flagged-collateral exits that were impossible under RiskModuleStub.
contract RiskModuleIntegrationTest is Test {
    BalanceLedger internal ledger;
    HubDepositor internal depositor;
    WithdrawalRegistry internal registry;
    CollateralManager internal cm;
    OracleRouter internal router;
    RiskModule internal rm;
    MockCentuariDebt internal debtSrc;

    PushOracle internal pushUsdc;
    PushOracle internal pushUsdt;
    MockToken internal usdc; // 6 decimals
    MockToken internal usdt; // 6 decimals

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal user = makeAddr("user");

    uint256 internal constant DEPOSIT = 100_000e6;
    uint256 internal constant DEBT = 40_000e6;

    function _proxy(address impl, bytes memory initData) internal returns (address) {
        return address(new TransparentUpgradeableProxy(impl, address(this), initData));
    }

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        usdt = new MockToken("Tether USD", "USDT", 6, 0);

        ledger = BalanceLedger(_proxy(address(new BalanceLedger()), abi.encodeCall(BalanceLedger.initialize, (owner, true))));
        depositor =
            HubDepositor(_proxy(address(new HubDepositor()), abi.encodeCall(HubDepositor.initialize, (owner, address(ledger)))));
        router = OracleRouter(_proxy(address(new OracleRouter()), abi.encodeCall(OracleRouter.initialize, (owner))));
        debtSrc = new MockCentuariDebt();

        pushUsdc = new PushOracle(owner, operator);
        pushUsdt = new PushOracle(owner, operator);

        rm = RiskModule(
            _proxy(
                address(new RiskModule()),
                abi.encodeCall(RiskModule.initialize, (owner, address(router), address(debtSrc), address(ledger)))
            )
        );
        registry = WithdrawalRegistry(
            _proxy(
                address(new WithdrawalRegistry()),
                abi.encodeCall(
                    WithdrawalRegistry.initialize, (owner, operator, address(ledger), address(rm), address(depositor))
                )
            )
        );
        cm = CollateralManager(
            _proxy(
                address(new CollateralManager()),
                abi.encodeCall(CollateralManager.initialize, (owner, operator, address(ledger), address(rm)))
            )
        );

        vm.startPrank(owner);
        ledger.forceAddWriter(address(depositor));
        ledger.forceAddWriter(address(registry));
        ledger.forceAddWriter(address(cm));
        depositor.addSupportedAsset(address(usdc));
        depositor.addSupportedAsset(address(usdt));
        depositor.setAuthorizedCaller(address(registry), true);
        router.setFeed(address(usdc), address(pushUsdc));
        router.setFeed(address(usdt), address(pushUsdt));
        rm.setDefaultBuffer(0);
        rm.setLtv(address(usdc), 8000);
        rm.setLtv(address(usdt), 8000);
        cm.setFlagLock(0); // skip the 24h flag-lock for these gate tests
        vm.stopPrank();

        vm.startPrank(operator);
        pushUsdc.setPrice(1e18); // $1
        pushUsdt.setPrice(1e18); // $1
        vm.stopPrank();

        // Base position: deposit + flag 100k USDC, owe 40k USDC-denominated debt.
        _depositAndFlag(usdc, DEPOSIT);
        address[] memory dt = new address[](1);
        dt[0] = address(usdc);
        uint256[] memory da = new uint256[](1);
        da[0] = DEBT;
        debtSrc.setDebts(user, dt, da);
    }

    function _depositAndFlag(MockToken token, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(depositor), amount);
        depositor.deposit(address(token), amount);
        vm.stopPrank();
        vm.prank(operator);
        cm.flagFor(user, address(token));
    }

    // ---- Governance swap (interface acceptance) ----

    function test_setRiskModule_swapAcceptedByBothCallers() public {
        RiskModule rm2 = RiskModule(
            _proxy(
                address(new RiskModule()),
                abi.encodeCall(RiskModule.initialize, (owner, address(router), address(debtSrc), address(ledger)))
            )
        );
        vm.startPrank(owner);
        registry.setRiskModule(address(rm2));
        cm.setRiskModule(address(rm2));
        vm.stopPrank();
        assertEq(registry.riskModule(), address(rm2));
        assertEq(cm.riskModule(), address(rm2));
    }

    // ---- WithdrawalRegistry gate via the real module ----

    /// @dev Impossible under RiskModuleStub (which blocks ANY flagged withdrawal).
    function test_withdrawRegistry_flaggedHealthyWithdrawal_succeeds() public {
        uint256 amount = 5_000e6; // post-HF = (95k-40k)*0.8/40k = 1.1 ≥ 1.0

        vm.prank(operator);
        registry.requestWithdrawalFor(user, address(usdc), amount, block.chainid);

        assertEq(ledger.available(user, address(usdc)), DEPOSIT - amount);
        assertEq(usdc.balanceOf(user), amount); // payoutDirect transferred out
    }

    function test_withdrawRegistry_unhealthyWithdrawal_blocked() public {
        uint256 amount = 70_000e6; // post-HF: collateral 30k < debt 40k → HF ≤ 0

        vm.prank(operator);
        vm.expectRevert(IWithdrawalRegistry.WithdrawalBlockedByHF.selector);
        registry.requestWithdrawalFor(user, address(usdc), amount, block.chainid);
    }

    // ---- CollateralManager gate via the real module ----

    /// @dev Impossible under RiskModuleStub (canUnflag always false). Here a
    ///      second healthy collateral keeps HF ≥ 1 after unflagging the first.
    function test_collateralManager_unflagHealthy_succeeds() public {
        _depositAndFlag(usdt, DEPOSIT); // second collateral

        vm.prank(operator);
        cm.unflagFor(user, address(usdc));

        assertFalse(ledger.usedAsCollateral(user, address(usdc)));
        assertTrue(ledger.usedAsCollateral(user, address(usdt)));
    }

    function test_collateralManager_unflagUnhealthy_blocked() public {
        // Single collateral + outstanding debt → unflagging removes all backing.
        vm.prank(operator);
        vm.expectRevert(ICollateralManager.WouldMakeUnhealthy.selector);
        cm.unflagFor(user, address(usdc));
    }

    /// @dev With debt fully cleared, the real module permits unflagging the last
    ///      collateral — the no-repay-first end-state the stub could not deliver.
    function test_collateralManager_unflagAfterDebtCleared_succeeds() public {
        debtSrc.setDebts(user, new address[](0), new uint256[](0)); // debt repaid

        vm.prank(operator);
        cm.unflagFor(user, address(usdc));
        assertFalse(ledger.usedAsCollateral(user, address(usdc)));
    }
}
