// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PCBTVault} from "../../src/core/pcbt/PCBTVault.sol";
import {PCBTVaultFactory} from "../../src/core/pcbt/PCBTVaultFactory.sol";
import {IPCBT} from "../../src/interfaces/IPCBT.sol";
import {ICBT} from "../../src/interfaces/ICBT.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ Mock Contracts ============

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract MockCBT is ERC20 {
    address internal _underlyingAsset;
    uint256 internal _maturityTs;
    address internal _endpointAddr;

    constructor(address underlying_, uint256 maturity_, address endpoint_)
        ERC20("CBT-USDC-2026-07-01", "CBT-USDC-2026-07-01")
    {
        _underlyingAsset = underlying_;
        _maturityTs = maturity_;
        _endpointAddr = endpoint_;
    }

    function underlying() external view returns (address) { return _underlyingAsset; }
    function maturity() external view returns (uint256) { return _maturityTs; }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

contract MockRateOracle {
    function getCBTFairValue(address) external pure returns (uint256) {
        return 0.99e18; // 99 cents per CBT (pre-maturity)
    }
}

contract PCBTVaultTest is Test {
    PCBTVault public vault;
    MockUSDC public usdc;
    MockCBT public cbt;
    MockRateOracle public oracle;

    address public owner = address(0x1);
    address public endpoint = address(0x2);
    address public router = address(0x3);
    address public proxyAdmin = address(0x4);
    address public userA = address(0x10);
    address public userB = address(0x20);

    uint256 public constant MATURITY = 1751328000; // July 1, 2026

    function setUp() public {
        vm.warp(1719792000); // June 1, 2026

        usdc = new MockUSDC();
        cbt = new MockCBT(address(usdc), MATURITY, endpoint);
        oracle = new MockRateOracle();

        // Deploy vault via proxy
        PCBTVault impl = new PCBTVault();
        bytes memory initData = abi.encodeCall(
            PCBTVault.initialize,
            (owner, address(usdc), address(oracle), router, endpoint, "Perpetual CBT USDC", "pCBT-USDC")
        );
        vault = PCBTVault(address(new TransparentUpgradeableProxy(
            address(impl), proxyAdmin, initData
        )));

        // Set current CBT
        vm.prank(owner);
        vault.setCurrentCBT(address(cbt));

        // Mint CBT to users
        cbt.mint(userA, 10_000e6);
        cbt.mint(userB, 5_000e6);

        // Approve vault
        vm.prank(userA);
        cbt.approve(address(vault), type(uint256).max);
        vm.prank(userB);
        cbt.approve(address(vault), type(uint256).max);
    }

    // ============ Initialization ============

    function test_initialize() public view {
        assertEq(vault.loanToken(), address(usdc));
        assertEq(vault.currentCBTAddress(), address(cbt));
        assertEq(vault.name(), "Perpetual CBT USDC");
        assertEq(vault.symbol(), "pCBT-USDC");
        // Seed deposit: VIRTUAL_OFFSET minted to dead address
        assertTrue(vault.totalSupply() > 0);
        assertTrue(vault.balanceOf(address(1)) > 0);
    }

    // ============ Deposit ============

    function test_depositCBT_mintsCorrectShares() public {
        vm.prank(userA);
        uint256 shares = vault.depositCBT(10_000e6);

        assertTrue(shares > 0);
        assertEq(vault.balanceOf(userA), shares);
        assertEq(cbt.balanceOf(address(vault)), 10_000e6);
    }

    function test_depositCBT_zeroAmount_reverts() public {
        vm.prank(userA);
        vm.expectRevert(IPCBT.ZeroAmount.selector);
        vault.depositCBT(0);
    }

    function test_depositCBT_multipleDifferentUsers() public {
        vm.prank(userA);
        uint256 sharesA = vault.depositCBT(10_000e6);

        vm.prank(userB);
        uint256 sharesB = vault.depositCBT(5_000e6);

        // UserA deposited 2x, should have ~2x shares
        assertApproxEqRel(sharesA, sharesB * 2, 0.01e18); // within 1%
    }

    function test_depositCBT_inflationAttackFails() public {
        // Attacker deposits 1 wei
        cbt.mint(address(0x99), 1);
        vm.startPrank(address(0x99));
        cbt.approve(address(vault), 1);
        vault.depositCBT(1);
        vm.stopPrank();

        // Attacker donates a large amount directly to vault (inflation attack)
        cbt.mint(address(vault), 1_000_000e6);

        // Victim deposits 10,000 USDC worth of CBT
        vm.prank(userA);
        uint256 victimShares = vault.depositCBT(10_000e6);

        // Victim should still get meaningful shares (not 0)
        assertTrue(victimShares > 0);
    }

    // ============ Share Price ============

    function test_sharePrice_reflectsCBTFairValue() public {
        vm.prank(userA);
        vault.depositCBT(10_000e6);

        uint256 price = vault.sharePrice();
        assertTrue(price > 0);
    }

    function test_sharePrice_usesInternalAccounting() public {
        vm.prank(userA);
        vault.depositCBT(10_000e6);

        uint256 priceBefore = vault.sharePrice();

        // Donate tokens directly (should NOT affect share price since we use internal accounting)
        cbt.mint(address(vault), 50_000e6);

        uint256 priceAfter = vault.sharePrice();

        // Price should be same (internal accounting, not balanceOf)
        assertEq(priceBefore, priceAfter);
    }

    // ============ Withdrawal ============

    function test_requestWithdrawal_addsToQueue() public {
        vm.startPrank(userA);
        vault.depositCBT(10_000e6);
        vault.requestWithdrawal(vault.balanceOf(userA));
        vm.stopPrank();

        assertEq(vault.withdrawalQueueLength(), 1);
    }

    function test_requestWithdrawal_insufficientShares_reverts() public {
        vm.startPrank(userA);
        vault.depositCBT(10_000e6);
        uint256 shares = vault.balanceOf(userA);
        vm.expectRevert(IPCBT.InsufficientShares.selector);
        vault.requestWithdrawal(shares + 1);
        vm.stopPrank();
    }

    function test_requestWithdrawal_afterCutoff_reverts() public {
        vm.prank(userA);
        uint256 shares = vault.depositCBT(10_000e6);

        // Explicitly set next maturity to ensure it's stored
        vm.prank(owner);
        vault.setNextMaturity(MATURITY);

        // Warp to within 24h of maturity (23h before)
        vm.warp(MATURITY - 23 hours);

        vm.prank(userA);
        vm.expectRevert(IPCBT.WithdrawalCutoffPassed.selector);
        vault.requestWithdrawal(shares);
    }

    function test_cancelWithdrawal_removesFromQueue() public {
        vm.startPrank(userA);
        vault.depositCBT(10_000e6);
        vault.requestWithdrawal(vault.balanceOf(userA));
        assertEq(vault.withdrawalQueueLength(), 1);
        vault.cancelWithdrawal();
        vm.stopPrank();

        assertEq(vault.withdrawalQueueLength(), 0);
    }

    function test_cancelWithdrawal_noRequest_reverts() public {
        vm.prank(userA);
        vm.expectRevert(IPCBT.NoWithdrawalPending.selector);
        vault.cancelWithdrawal();
    }

    // ============ Early Exit ============

    function test_requestEarlyExit_stores() public {
        vm.startPrank(userA);
        vault.depositCBT(10_000e6);
        vault.requestEarlyExit(vault.balanceOf(userA), 0, 0);
        vm.stopPrank();
    }

    function test_cancelEarlyExit() public {
        vm.startPrank(userA);
        vault.depositCBT(10_000e6);
        vault.requestEarlyExit(vault.balanceOf(userA), 0, 0);
        vault.cancelEarlyExit();
        vm.stopPrank();
    }

    function test_cancelEarlyExit_noPending_reverts() public {
        vm.prank(userA);
        vm.expectRevert(IPCBT.NoEarlyExitPending.selector);
        vault.cancelEarlyExit();
    }

    // ============ Settlement ============

    function test_onSettlement_onlyEndpoint() public {
        vm.prank(userA);
        vm.expectRevert(IPCBT.OnlyEndpoint.selector);
        vault.onSettlement(address(0), 0, 0);
    }

    function test_onSettlement_updatesCurrentCBT() public {
        vm.prank(userA);
        vault.depositCBT(10_000e6);

        address newCBT = address(new MockCBT(address(usdc), MATURITY + 30 days, endpoint));

        // Mint USDC to vault for withdrawal payouts
        usdc.mint(address(vault), 10_000e6);

        vm.prank(endpoint);
        vault.onSettlement(newCBT, 10_000e6, 10_000e6);

        assertEq(vault.currentCBTAddress(), newCBT);
    }

    function test_onSettlement_processesWithdrawalQueue() public {
        vm.prank(userA);
        uint256 shares = vault.depositCBT(10_000e6);

        vm.prank(userA);
        vault.requestWithdrawal(shares);

        address newCBT = address(new MockCBT(address(usdc), MATURITY + 30 days, endpoint));

        // Mint USDC to vault for withdrawal payouts
        usdc.mint(address(vault), 10_000e6);

        vm.prank(endpoint);
        vault.onSettlement(newCBT, 0, 10_000e6);

        // UserA should have received USDC
        assertTrue(usdc.balanceOf(userA) > 0);
        // pCBT shares should be burned
        assertEq(vault.balanceOf(userA), 0);
        // Queue should be empty
        assertEq(vault.withdrawalQueueLength(), 0);
    }

    // ============ Total Assets ============

    function test_totalAssets_breakdown() public {
        vm.prank(userA);
        vault.depositCBT(10_000e6);

        (uint256 cbtHeld, uint256 cbtFairValue, uint256 idleUSDC) = vault.totalAssets();
        assertEq(cbtHeld, 10_000e6);
        assertTrue(cbtFairValue > 0);
        assertEq(idleUSDC, 0);
    }

    // ============ Collateral Value ============

    function test_collateralValuePerPCBT() public {
        vm.prank(userA);
        vault.depositCBT(10_000e6);

        uint256 value = vault.collateralValuePerPCBT();
        assertTrue(value > 0);
    }

    // ============ Factory ============

    function test_factory_createsVault() public {
        PCBTVaultFactory factory = new PCBTVaultFactory(owner, proxyAdmin);

        vm.prank(owner);
        address vaultAddr = factory.createVault(
            address(usdc),
            address(oracle),
            router,
            endpoint,
            "pCBT-USDC",
            "pCBT-USDC"
        );

        assertTrue(vaultAddr != address(0));
        assertEq(factory.getVault(address(usdc)), vaultAddr);
        assertEq(factory.vaultCount(), 1);
    }

    function test_factory_duplicateReverts() public {
        PCBTVaultFactory factory = new PCBTVaultFactory(owner, proxyAdmin);

        vm.prank(owner);
        factory.createVault(address(usdc), address(oracle), router, endpoint, "pCBT-USDC", "pCBT-USDC");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PCBTVaultFactory.VaultAlreadyExists.selector, address(usdc)));
        factory.createVault(address(usdc), address(oracle), router, endpoint, "pCBT-USDC", "pCBT-USDC");
    }
}
