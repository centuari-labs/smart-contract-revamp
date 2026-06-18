// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {RiskModule} from "../../src/core/risk/RiskModule.sol";

/// @notice Oracle mock returning a preset USD value per asset (amount-independent).
contract MockHFOracle {
    mapping(address => uint256) internal _value;
    mapping(address => bool) internal _ok;

    function set(address asset, uint256 value1e18, bool ok) external {
        _value[asset] = value1e18;
        _ok[asset] = ok;
    }

    function tryGetUsdValue(address asset, uint256) external view returns (uint256, bool) {
        return (_value[asset], _ok[asset]);
    }
}

/// @notice Minimal BalanceLedger mock exposing only what RiskModule reads.
contract MockHFLedger {
    mapping(address => address[]) internal _flagged;
    mapping(address => mapping(address => uint256)) internal _available;
    mapping(address => mapping(address => bool)) internal _used;

    function setFlagged(address user, address[] calldata assets) external {
        delete _flagged[user];
        for (uint256 i = 0; i < assets.length; ++i) {
            _flagged[user].push(assets[i]);
        }
    }

    function setAvailable(address user, address asset, uint256 amt) external {
        _available[user][asset] = amt;
    }

    function setUsed(address user, address asset, bool v) external {
        _used[user][asset] = v;
    }

    function flaggedAssetsOf(address user) external view returns (address[] memory) {
        return _flagged[user];
    }

    function available(address user, address asset) external view returns (uint256) {
        return _available[user][asset];
    }

    function usedAsCollateral(address user, address asset) external view returns (bool) {
        return _used[user][asset];
    }
}

/// @notice Debt source mock matching ICentuari.getBorrowerDebts.
contract MockHFDebt {
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

/// @title RiskModuleHFCrossCheck
/// @notice SC-9: locks the on-chain HF verdict to the backend HF verdict using a
///         SHARED fixture (test/fixtures/hf-cross-check-vectors.json). The backend
///         jest test (backend-v2/.../hf-cross-check.test.ts) asserts the same
///         vectors against `computeHealthFactor`, so neither side can drift.
contract RiskModuleHFCrossCheckTest is Test {
    RiskModule internal rm;
    MockHFOracle internal oracle;
    MockHFLedger internal ledger;
    MockHFDebt internal debtSrc;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal asset0 = address(0xA0);
    address internal asset1 = address(0xA1);
    address internal debtAsset = address(0xD0);

    function setUp() public {
        oracle = new MockHFOracle();
        ledger = new MockHFLedger();
        debtSrc = new MockHFDebt();
        RiskModule impl = new RiskModule();
        bytes memory initData =
            abi.encodeCall(RiskModule.initialize, (owner, address(oracle), address(debtSrc), address(ledger)));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), makeAddr("admin"), initData);
        rm = RiskModule(address(proxy));
    }

    function test_hfVerdicts_matchSharedVectors() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/hf-cross-check-vectors.json"));
        uint256[] memory bufferBps = vm.parseJsonUintArray(json, ".bufferBps");
        uint256[] memory coll0Value = vm.parseJsonUintArray(json, ".coll0Value");
        uint256[] memory coll0Ltv = vm.parseJsonUintArray(json, ".coll0Ltv");
        uint256[] memory coll1Value = vm.parseJsonUintArray(json, ".coll1Value");
        uint256[] memory coll1Ltv = vm.parseJsonUintArray(json, ".coll1Ltv");
        uint256[] memory debt0Value = vm.parseJsonUintArray(json, ".debt0Value");
        bool[] memory expectedHealthy = vm.parseJsonBoolArray(json, ".expectedHealthy");
        string[] memory names = vm.parseJsonStringArray(json, ".name");

        for (uint256 i = 0; i < bufferBps.length; ++i) {
            _configureVector(coll0Value[i], coll0Ltv[i], coll1Value[i], coll1Ltv[i], debt0Value[i], bufferBps[i]);
            bool got = rm.canWithdraw(user, asset0, 0); // amount 0 → verdict for the current state
            assertEq(got, expectedHealthy[i], names[i]);
        }
    }

    function _configureVector(
        uint256 coll0Value,
        uint256 coll0Ltv,
        uint256 coll1Value,
        uint256 coll1Ltv,
        uint256 debt0Value,
        uint256 bufferBps
    ) internal {
        bool twoCollateral = coll1Value > 0;

        // Oracle: USD values are 1e18-scaled (HF is scale-invariant vs the human
        // values the backend uses).
        oracle.set(asset0, coll0Value * 1e18, true);
        if (twoCollateral) oracle.set(asset1, coll1Value * 1e18, true);
        oracle.set(debtAsset, debt0Value * 1e18, true);

        // Ledger: flag the collateral; amounts are nominal (oracle is amount-independent).
        address[] memory flagged = new address[](twoCollateral ? 2 : 1);
        flagged[0] = asset0;
        if (twoCollateral) flagged[1] = asset1;
        ledger.setFlagged(user, flagged);
        ledger.setAvailable(user, asset0, 1);
        ledger.setUsed(user, asset0, true);
        if (twoCollateral) {
            ledger.setAvailable(user, asset1, 1);
            ledger.setUsed(user, asset1, true);
        }

        // Debt: empty when no debt so the debt-first short-circuit runs (SC-6).
        if (debt0Value > 0) {
            address[] memory dt = new address[](1);
            dt[0] = debtAsset;
            uint256[] memory da = new uint256[](1);
            da[0] = 1;
            debtSrc.setDebts(user, dt, da);
        } else {
            debtSrc.setDebts(user, new address[](0), new uint256[](0));
        }

        vm.startPrank(owner);
        rm.setDefaultBuffer(bufferBps);
        rm.setLtv(asset0, coll0Ltv);
        if (twoCollateral) rm.setLtv(asset1, coll1Ltv);
        vm.stopPrank();
    }
}
