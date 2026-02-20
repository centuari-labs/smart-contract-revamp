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
        faucet = new Faucet(operator); // Constructor requires operator

        token.grantRole(token.MINTER_ROLE(), address(faucet));

        // Single operator is set in constructor
        vm.prank(operator);
        faucet.addToken(address(token), MAX_PER_REQUEST, 0);
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
        vm.prank(operator);
        faucet.addToken(address(token), MAX_PER_REQUEST, COOLDOWN);

        vm.prank(operator);
        faucet.mintTo(address(token), recipient, 100 * 10 ** 6);

        vm.prank(operator);
        vm.expectRevert(Faucet.CooldownNotElapsed.selector);
        faucet.mintTo(address(token), recipient, 50 * 10 ** 6);
    }

    function test_mintTo_cooldown_afterCooldownSucceeds() public {
        faucet.removeToken(address(token));
        vm.prank(operator);
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

    function test_mintTo_invalidAddress_tokenZeroReverts() public {
        vm.prank(operator);
        vm.expectRevert(Faucet.InvalidAddress.selector);
        faucet.mintTo(address(0), recipient, 100 * 10 ** 6);
    }

    function test_mintTo_invalidAmount_reverts() public {
        vm.prank(operator);
        vm.expectRevert(Faucet.InvalidAmount.selector);
        faucet.mintTo(address(token), recipient, 0);
    }

    // --- Operator & Batch tests ---

    function test_setOperator_onlyOwner() public {
        address newOp = makeAddr("newOp");
        faucet.setOperator(newOp);
        assertEq(faucet.operator(), newOp);

        vm.prank(recipient);
        vm.expectRevert(); // Ownable: caller is not the owner
        faucet.setOperator(recipient);
    }

    function test_addToken_operatorCanAdd() public {
        MockToken t2 = new MockToken("Test", "TST", 18, 0);
        t2.grantRole(t2.MINTER_ROLE(), address(faucet));

        vm.prank(operator);
        faucet.addToken(address(t2), 1000, 0);

        (bool enabled, , ) = faucet.configOf(address(t2));
        assertTrue(enabled);
    }

    function test_mintBatch_happyPath() public {
        MockToken t2 = new MockToken("Token 2", "T2", 6, 0);
        t2.grantRole(t2.MINTER_ROLE(), address(faucet));
        vm.prank(operator);
        faucet.addToken(address(t2), MAX_PER_REQUEST, 0);

        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(t2);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 * 10 ** 6;
        amounts[1] = 200 * 10 ** 6;

        vm.prank(operator);
        faucet.mintBatch(tokens, amounts, recipient);

        assertEq(token.balanceOf(recipient), 100 * 10 ** 6);
        assertEq(t2.balanceOf(recipient), 200 * 10 ** 6);
    }

    function test_mintBatch_maxBatch_reverts() public {
        uint256 maxPlusOne = 10; // MAX_BATCH + 1
        address[] memory tokens = new address[](maxPlusOne);
        uint256[] memory amounts = new uint256[](maxPlusOne);

        vm.prank(operator);
        vm.expectRevert(Faucet.BatchTooLarge.selector);
        faucet.mintBatch(tokens, amounts, recipient);
    }

    function test_mintBatch_arrayMismatch_reverts() public {
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](1);

        vm.prank(operator);
        vm.expectRevert(Faucet.ArrayLengthMismatch.selector);
        faucet.mintBatch(tokens, amounts, recipient);
    }

    function test_lastMintAt_updatedWhenCooldownSet() public {
        faucet.removeToken(address(token));
        vm.prank(operator);
        faucet.addToken(address(token), MAX_PER_REQUEST, COOLDOWN);

        vm.prank(operator);
        faucet.mintTo(address(token), recipient, 100 * 10 ** 6);

        assertEq(faucet.lastMintAt(address(token), recipient), block.timestamp);
    }
}
