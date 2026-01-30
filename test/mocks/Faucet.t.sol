// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {Faucet} from "../../src/mocks/Faucet.sol";

contract FaucetTest is Test {
    MockToken public token;
    Faucet public faucet;
    address public owner;
    address public operator;
    address public recipient;

    uint256 constant INITIAL_SUPPLY = 1_000_000 * 10 ** 6;
    uint256 constant MAX_PER_REQUEST = 10_000 * 10 ** 6;
    uint256 constant COOLDOWN = 24 hours;

    function setUp() public {
        owner = address(this);
        operator = makeAddr("operator");
        recipient = makeAddr("recipient");

        token = new MockToken("USD Coin", "USDC", 6, INITIAL_SUPPLY);
        faucet = new Faucet();

        token.grantRole(token.MINTER_ROLE(), address(faucet));
        faucet.addToken(address(token), MAX_PER_REQUEST, 0);
        faucet.setOperator(operator);
    }

    function test_mintTo_happyPath() public {
        uint256 amount = 100 * 10 ** 6;
        vm.prank(operator);
        faucet.mintTo(address(token), recipient, amount);

        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + amount);
    }

    function test_mintTo_onlyOperator_succeedsWhenOperator() public {
        vm.prank(operator);
        faucet.mintTo(address(token), recipient, 50 * 10 ** 6);
        assertEq(token.balanceOf(recipient), 50 * 10 ** 6);
    }

    function test_mintTo_onlyOperator_revertsWhenNotOperator() public {
        vm.prank(recipient);
        vm.expectRevert(Faucet.OnlyOperator.selector);
        faucet.mintTo(address(token), recipient, 100 * 10 ** 6);
    }

    function test_mintTo_onlyOperator_revertsWhenOwnerButNotOperator() public {
        vm.prank(owner);
        vm.expectRevert(Faucet.OnlyOperator.selector);
        faucet.mintTo(address(token), recipient, 100 * 10 ** 6);
    }

    function test_mintTo_cooldown_secondMintWithinCooldownReverts() public {
        faucet.removeToken(address(token));
        faucet.addToken(address(token), MAX_PER_REQUEST, COOLDOWN);

        vm.prank(operator);
        faucet.mintTo(address(token), recipient, 100 * 10 ** 6);

        vm.prank(operator);
        vm.expectRevert(Faucet.CooldownNotElapsed.selector);
        faucet.mintTo(address(token), recipient, 50 * 10 ** 6);
    }

    function test_mintTo_cooldown_afterCooldownSucceeds() public {
        faucet.removeToken(address(token));
        faucet.addToken(address(token), MAX_PER_REQUEST, COOLDOWN);

        vm.prank(operator);
        faucet.mintTo(address(token), recipient, 100 * 10 ** 6);

        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(operator);
        faucet.mintTo(address(token), recipient, 50 * 10 ** 6);

        assertEq(token.balanceOf(recipient), 150 * 10 ** 6);
    }

    function test_mintTo_maxPerRequest_aboveReverts() public {
        vm.prank(operator);
        vm.expectRevert(Faucet.ExceedsMaxPerRequest.selector);
        faucet.mintTo(address(token), recipient, MAX_PER_REQUEST + 1);
    }

    function test_mintTo_maxPerRequest_atLimitSucceeds() public {
        vm.prank(operator);
        faucet.mintTo(address(token), recipient, MAX_PER_REQUEST);
        assertEq(token.balanceOf(recipient), MAX_PER_REQUEST);
    }

    function test_mintTo_disabledToken_reverts() public {
        faucet.removeToken(address(token));

        vm.prank(operator);
        vm.expectRevert(Faucet.TokenNotEnabled.selector);
        faucet.mintTo(address(token), recipient, 100 * 10 ** 6);
    }

    function test_mintTo_beforeGrantingMinter_reverts() public {
        MockToken otherToken = new MockToken("Tether", "USDT", 6, 0);
        faucet.addToken(address(otherToken), MAX_PER_REQUEST, 0);
        // Faucet does not have MINTER_ROLE on otherToken

        vm.prank(operator);
        vm.expectRevert();
        faucet.mintTo(address(otherToken), recipient, 100 * 10 ** 6);
    }

    function test_mintTo_afterGrantingMinter_succeeds() public {
        MockToken otherToken = new MockToken("Tether", "USDT", 6, 0);
        otherToken.grantRole(otherToken.MINTER_ROLE(), address(faucet));
        faucet.addToken(address(otherToken), MAX_PER_REQUEST, 0);

        vm.prank(operator);
        faucet.mintTo(address(otherToken), recipient, 100 * 10 ** 6);
        assertEq(otherToken.balanceOf(recipient), 100 * 10 ** 6);
    }

    function test_mintTo_invalidAddress_tokenZeroReverts() public {
        vm.prank(operator);
        vm.expectRevert(Faucet.InvalidAddress.selector);
        faucet.mintTo(address(0), recipient, 100 * 10 ** 6);
    }

    function test_mintTo_invalidAddress_recipientZeroReverts() public {
        vm.prank(operator);
        vm.expectRevert(Faucet.InvalidAddress.selector);
        faucet.mintTo(address(token), address(0), 100 * 10 ** 6);
    }

    function test_mintTo_invalidAmount_reverts() public {
        vm.prank(operator);
        vm.expectRevert(Faucet.InvalidAmount.selector);
        faucet.mintTo(address(token), recipient, 0);
    }

    function test_addToken_onlyOwner_revertsWhenNotOwner() public {
        vm.prank(recipient);
        vm.expectRevert();
        faucet.addToken(address(token), MAX_PER_REQUEST, 0);
    }

    function test_removeToken_onlyOwner_revertsWhenNotOwner() public {
        vm.prank(recipient);
        vm.expectRevert();
        faucet.removeToken(address(token));
    }

    function test_setTokenConfig_onlyOwner_revertsWhenNotOwner() public {
        vm.prank(recipient);
        vm.expectRevert();
        faucet.setTokenConfig(address(token), 5_000 * 10 ** 6, 1 hours);
    }

    function test_setOperator_onlyOwner_revertsWhenNotOwner() public {
        vm.prank(recipient);
        vm.expectRevert();
        faucet.setOperator(recipient);
    }

    function test_setOperator_onlyOwner_succeedsWhenOwner() public {
        address newOperator = makeAddr("newOperator");
        faucet.setOperator(newOperator);
        assertEq(faucet.operator(), newOperator);

        vm.prank(operator);
        vm.expectRevert(Faucet.OnlyOperator.selector);
        faucet.mintTo(address(token), recipient, 100 * 10 ** 6);

        vm.prank(newOperator);
        faucet.mintTo(address(token), recipient, 100 * 10 ** 6);
        assertEq(token.balanceOf(recipient), 100 * 10 ** 6);
    }

    function test_lastMintAt_updatedWhenCooldownSet() public {
        faucet.removeToken(address(token));
        faucet.addToken(address(token), MAX_PER_REQUEST, COOLDOWN);

        vm.prank(operator);
        faucet.mintTo(address(token), recipient, 100 * 10 ** 6);

        assertEq(faucet.lastMintAt(address(token), recipient), block.timestamp);
    }
}
