// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

contract MockTokenTest is Test {
    MockToken public token;
    address public owner;
    address public user;

    function setUp() public {
        owner = address(this);
        user = makeAddr("user");
        token = new MockToken("USD Coin", "USDC", 6, 1_000_000 * 10 ** 6);
    }

    function test_metadata() public view {
        assertEq(token.name(), "USD Coin");
        assertEq(token.symbol(), "USDC");
        assertEq(token.decimals(), 6);
    }

    function test_initialSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000 * 10 ** 6);
        assertEq(token.balanceOf(owner), 1_000_000 * 10 ** 6);
    }

    function test_mint_asMinter() public {
        uint256 amount = 100 * 10 ** 6;
        token.mint(user, amount);
        assertEq(token.balanceOf(user), amount);
        assertEq(token.totalSupply(), 1_000_000 * 10 ** 6 + amount);
    }

    function test_mint_revertWhenNotMinter() public {
        vm.prank(user);
        vm.expectRevert();
        token.mint(user, 100 * 10 ** 6);
    }

    function test_grantMinterRole_canMint() public {
        address minterAddr = makeAddr("minter");
        token.grantRole(token.MINTER_ROLE(), minterAddr);

        vm.prank(minterAddr);
        token.mint(user, 200 * 10 ** 6);
        assertEq(token.balanceOf(user), 200 * 10 ** 6);
    }

    function test_constructor_zeroInitialSupply() public {
        MockToken noSupply = new MockToken("Tether", "USDT", 6, 0);
        assertEq(noSupply.totalSupply(), 0);
        assertEq(noSupply.balanceOf(owner), 0);
        noSupply.mint(user, 500 * 10 ** 6);
        assertEq(noSupply.balanceOf(user), 500 * 10 ** 6);
    }

    function test_decimals_override() public {
        MockToken btc = new MockToken("Bitcoin", "BTC", 8, 1000 * 10 ** 8);
        assertEq(btc.decimals(), 8);
        assertEq(btc.totalSupply(), 1000 * 10 ** 8);
    }
}
