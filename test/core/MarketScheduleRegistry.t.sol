// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MarketScheduleRegistry} from "../../src/core/MarketScheduleRegistry.sol";
import {IMarketScheduleRegistry} from "../../src/interfaces/IMarketScheduleRegistry.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract MarketScheduleRegistryTest is Test {
    MarketScheduleRegistry public registry;

    address public owner = address(0x1);
    bytes32 public NYSE_ID = keccak256("NYSE");
    bytes32 public LSE_ID = keccak256("LSE");

    // NYSE hours: 9:30 AM - 4:00 PM ET = 14:30 - 21:00 UTC
    uint256 public constant NYSE_OPEN = 14 hours + 30 minutes;  // 52200
    uint256 public constant NYSE_CLOSE = 21 hours;               // 75600

    function setUp() public {
        MarketScheduleRegistry impl = new MarketScheduleRegistry();
        bytes memory initData = abi.encodeCall(MarketScheduleRegistry.initialize, (owner));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), owner, initData
        );
        registry = MarketScheduleRegistry(address(proxy));
    }

    function _addNYSESchedule() internal {
        uint8[] memory tradingDays = new uint8[](5);
        tradingDays[0] = 1; // Mon
        tradingDays[1] = 2; // Tue
        tradingDays[2] = 3; // Wed
        tradingDays[3] = 4; // Thu
        tradingDays[4] = 5; // Fri

        uint256[] memory holidays = new uint256[](0);

        IMarketScheduleRegistry.MarketSchedule memory schedule = IMarketScheduleRegistry.MarketSchedule({
            exchangeId: "NYSE",
            openTimeUTC: NYSE_OPEN,
            closeTimeUTC: NYSE_CLOSE,
            tradingDays: tradingDays,
            holidays: holidays
        });

        vm.prank(owner);
        registry.addSchedule(NYSE_ID, schedule);
    }

    // ============ Add Schedule Tests ============

    function test_addSchedule_success() public {
        _addNYSESchedule();

        IMarketScheduleRegistry.MarketSchedule memory s = registry.getSchedule(NYSE_ID);
        assertEq(s.openTimeUTC, NYSE_OPEN);
        assertEq(s.closeTimeUTC, NYSE_CLOSE);
        assertEq(s.tradingDays.length, 5);
    }

    function test_addSchedule_reverts_duplicate() public {
        _addNYSESchedule();

        uint8[] memory tradingDays = new uint8[](5);
        tradingDays[0] = 1;
        tradingDays[1] = 2;
        tradingDays[2] = 3;
        tradingDays[3] = 4;
        tradingDays[4] = 5;

        IMarketScheduleRegistry.MarketSchedule memory schedule = IMarketScheduleRegistry.MarketSchedule({
            exchangeId: "NYSE",
            openTimeUTC: NYSE_OPEN,
            closeTimeUTC: NYSE_CLOSE,
            tradingDays: tradingDays,
            holidays: new uint256[](0)
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMarketScheduleRegistry.ScheduleAlreadyExists.selector, NYSE_ID));
        registry.addSchedule(NYSE_ID, schedule);
    }

    // ============ isOpen Tests ============

    function test_isOpen_during_trading_hours() public {
        _addNYSESchedule();

        // Set to a known Wednesday at 3:00 PM UTC (within NYSE hours)
        // 2026-03-18 15:00 UTC = Wednesday
        uint256 wednesdayAfternoon = 1774026000; // approximate
        // More precisely: find a timestamp that is Wed 15:00 UTC
        // Jan 1 2026 is Thursday. Let's use Jan 7 2026 (Wednesday) at 15:00 UTC
        uint256 jan7_2026 = 1736208000; // Jan 7 2026 00:00 UTC (Wednesday)
        uint256 targetTime = jan7_2026 + 15 hours; // 15:00 UTC Wednesday

        vm.warp(targetTime);
        assertTrue(registry.isOpen(NYSE_ID));
    }

    function test_isOpen_before_market_opens() public {
        _addNYSESchedule();

        // Set to a Wednesday at 10:00 UTC (before NYSE 14:30 UTC open)
        uint256 jan7_2026 = 1736208000; // Jan 7 2026 00:00 UTC (Wednesday)
        uint256 targetTime = jan7_2026 + 10 hours;

        vm.warp(targetTime);
        assertFalse(registry.isOpen(NYSE_ID));
    }

    function test_isOpen_after_market_closes() public {
        _addNYSESchedule();

        // Set to a Wednesday at 22:00 UTC (after NYSE 21:00 UTC close)
        uint256 jan7_2026 = 1736208000;
        uint256 targetTime = jan7_2026 + 22 hours;

        vm.warp(targetTime);
        assertFalse(registry.isOpen(NYSE_ID));
    }

    function test_isOpen_weekend() public {
        _addNYSESchedule();

        // Saturday during "market hours" — should be closed
        // Jan 10 2026 is Saturday
        uint256 jan10_2026 = 1736467200;
        uint256 targetTime = jan10_2026 + 16 hours; // Saturday 16:00 UTC

        vm.warp(targetTime);
        assertFalse(registry.isOpen(NYSE_ID));
    }

    function test_isOpen_holiday() public {
        uint8[] memory tradingDays = new uint8[](5);
        tradingDays[0] = 1;
        tradingDays[1] = 2;
        tradingDays[2] = 3;
        tradingDays[3] = 4;
        tradingDays[4] = 5;

        // Add a holiday on Jan 7 2026 (Wednesday)
        uint256[] memory holidays = new uint256[](1);
        holidays[0] = 1736208000; // Jan 7 2026

        IMarketScheduleRegistry.MarketSchedule memory schedule = IMarketScheduleRegistry.MarketSchedule({
            exchangeId: "NYSE",
            openTimeUTC: NYSE_OPEN,
            closeTimeUTC: NYSE_CLOSE,
            tradingDays: tradingDays,
            holidays: holidays
        });

        vm.prank(owner);
        registry.addSchedule(LSE_ID, schedule); // use different ID

        // Warp to the holiday during trading hours
        vm.warp(1736208000 + 16 hours);
        assertFalse(registry.isOpen(LSE_ID));
    }

    function test_isOpen_reverts_unknown_schedule() public {
        vm.expectRevert(abi.encodeWithSelector(IMarketScheduleRegistry.ScheduleNotFound.selector, NYSE_ID));
        registry.isOpen(NYSE_ID);
    }

    // ============ Invalid Schedule Tests ============

    function test_addSchedule_reverts_empty_trading_days() public {
        IMarketScheduleRegistry.MarketSchedule memory schedule = IMarketScheduleRegistry.MarketSchedule({
            exchangeId: "BAD",
            openTimeUTC: NYSE_OPEN,
            closeTimeUTC: NYSE_CLOSE,
            tradingDays: new uint8[](0),
            holidays: new uint256[](0)
        });

        vm.prank(owner);
        vm.expectRevert(IMarketScheduleRegistry.InvalidSchedule.selector);
        registry.addSchedule(keccak256("BAD"), schedule);
    }

    function test_addSchedule_reverts_open_after_close() public {
        uint8[] memory tradingDays = new uint8[](1);
        tradingDays[0] = 1;

        IMarketScheduleRegistry.MarketSchedule memory schedule = IMarketScheduleRegistry.MarketSchedule({
            exchangeId: "BAD",
            openTimeUTC: NYSE_CLOSE,   // open AFTER close
            closeTimeUTC: NYSE_OPEN,
            tradingDays: tradingDays,
            holidays: new uint256[](0)
        });

        vm.prank(owner);
        vm.expectRevert(IMarketScheduleRegistry.InvalidSchedule.selector);
        registry.addSchedule(keccak256("BAD"), schedule);
    }
}
