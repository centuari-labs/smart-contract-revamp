// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {HubIntentSettler} from "../../src/core/HubIntentSettler.sol";
import {IHubIntentSettler} from "../../src/interfaces/IHubIntentSettler.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title FlowA_CrossChainDeposit
/// @notice Integration test: solver fills cross-chain deposit via HubIntentSettler
contract FlowA_CrossChainDepositTest is Test {
    BalanceLedger public ledger;
    HubIntentSettler public settler;
    MockToken public usdc;

    address owner = address(0x1);
    address solver = address(0x30);
    address user = address(0x10);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);

        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(
            address(new BalanceLedger()), owner,
            abi.encodeCall(BalanceLedger.initialize, (owner))
        )));

        settler = new HubIntentSettler(owner);

        // Wire up with timelocks
        vm.warp(100000);
        vm.startPrank(owner);
        ledger.proposeAuthorizedWriter(address(settler), true);
        vm.warp(100000 + 48 hours + 1);
        ledger.applyAuthorizedWriter();
        settler.proposeBalanceLedger(address(ledger));
        vm.warp(100000 + 96 hours + 2);
        settler.applyBalanceLedger();
        vm.stopPrank();

        // Fund solver
        usdc.mint(solver, 100_000e6);
    }

    /// @notice Solver fills a cross-chain deposit: USDC transferred, BalanceLedger credited
    function test_flowA_solver_fills_deposit() public {
        uint256 amount = 10_000e6;
        bytes32 orderId = keccak256("cross-chain-order-1");

        // Solver approves and fills
        vm.startPrank(solver);
        usdc.approve(address(settler), amount);

        vm.expectEmit(true, true, true, true);
        emit IHubIntentSettler.SolverFillRegistered(orderId, solver, user, address(usdc), amount);

        settler.fillFor(orderId, user, address(usdc), amount);
        vm.stopPrank();

        // User's BalanceLedger credited
        assertEq(ledger.getAvailable(user, address(usdc)), amount, "User should be credited");

        // Solver's USDC reduced
        assertEq(usdc.balanceOf(solver), 100_000e6 - amount, "Solver balance reduced");

        // Settler holds the USDC
        assertEq(usdc.balanceOf(address(settler)), amount, "Settler holds tokens");
    }

    /// @notice Zero address user reverts
    function test_flowA_zero_user_reverts() public {
        vm.startPrank(solver);
        usdc.approve(address(settler), 1000e6);
        vm.expectRevert(IHubIntentSettler.ZeroAddress.selector);
        settler.fillFor(bytes32(uint256(1)), address(0), address(usdc), 1000e6);
        vm.stopPrank();
    }
}
