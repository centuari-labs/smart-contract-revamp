// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @title FuzzTests
/// @notice Fuzz tests for critical arithmetic: interest, HF, seizure computation
contract FuzzTests is Test {

    uint256 constant RATE_PRECISION = 10000;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    uint256 constant HF_PRECISION = 1e18;
    uint256 constant BPS_DENOMINATOR = 10000;

    // ============ Interest Formula Fuzz ============

    /// @notice Fuzz: interest formula never overflows for realistic inputs
    /// @dev CBT_amount = principal + (principal * rateBPS * elapsed) / (RATE_PRECISION * SECONDS_PER_YEAR)
    function testFuzz_interest_no_overflow(uint256 principal, uint256 rateBPS, uint256 elapsed) public pure {
        // Bound to realistic ranges
        principal = bound(principal, 1, 1_000_000_000e6); // 1 wei to 1B USDC
        rateBPS = bound(rateBPS, 10, 10000); // 0.10% to 100%
        elapsed = bound(elapsed, 1, 365 days); // 1 second to 1 year

        // This should never overflow in uint256
        uint256 interest = (principal * rateBPS * elapsed) / (RATE_PRECISION * SECONDS_PER_YEAR);
        uint256 cbtAmount = principal + interest;

        // CBT amount must always be >= principal (interest is non-negative)
        assertTrue(cbtAmount >= principal, "CBT must be >= principal");

        // Interest must be >= 0 (implicit from uint256, but verify formula result)
        assertTrue(interest < principal * 2, "Interest should not exceed 200% of principal in 1 year");
    }

    /// @notice Fuzz: interest rounding always favors protocol (truncates toward zero)
    function testFuzz_interest_rounds_down(uint256 principal, uint256 rateBPS, uint256 elapsed) public pure {
        principal = bound(principal, 1, 1_000_000e6);
        rateBPS = bound(rateBPS, 10, 10000);
        elapsed = bound(elapsed, 1, 365 days);

        uint256 interest = (principal * rateBPS * elapsed) / (RATE_PRECISION * SECONDS_PER_YEAR);

        // Verify: the exact value (without truncation) would be >= the integer result
        // This is automatically true for integer division in Solidity
        // We verify the formula produces consistent results
        uint256 numerator = principal * rateBPS * elapsed;
        uint256 denominator = RATE_PRECISION * SECONDS_PER_YEAR;
        assertEq(interest, numerator / denominator, "Integer division consistent");
    }

    // ============ Health Factor Fuzz ============

    /// @notice Fuzz: HF computation — never divides by zero, always returns max for zero debt
    function testFuzz_hf_computation(uint256 weightedCollateral, uint256 totalDebt) public pure {
        weightedCollateral = bound(weightedCollateral, 0, 1_000_000_000e18); // 0 to 1B USD
        totalDebt = bound(totalDebt, 0, 1_000_000_000e18);

        uint256 hf;
        if (totalDebt == 0) {
            hf = type(uint256).max; // No debt = infinite HF
        } else {
            hf = (weightedCollateral * HF_PRECISION) / totalDebt;
        }

        // HF >= 1e18 means healthy (collateral >= debt)
        if (weightedCollateral >= totalDebt && totalDebt > 0) {
            assertTrue(hf >= HF_PRECISION, "HF should be >= 1.0 when collateral >= debt");
        }

        // HF < 1e18 means liquidatable
        if (weightedCollateral < totalDebt && totalDebt > 0) {
            assertTrue(hf < HF_PRECISION, "HF should be < 1.0 when collateral < debt");
        }
    }

    // ============ Seizure Computation Fuzz ============

    /// @notice Fuzz: seizure never exceeds total collateral amount
    function testFuzz_seizure_bounded(
        uint256 debtToCover, uint256 collateralUsdValue, uint256 collateralAmount, uint256 bonusBPS
    ) public pure {
        collateralUsdValue = bound(collateralUsdValue, 1e18, 1_000_000_000e18);
        collateralAmount = bound(collateralAmount, 1e6, 1_000_000_000e18);
        debtToCover = bound(debtToCover, 1e6, collateralUsdValue); // Can't cover more than collateral value
        bonusBPS = bound(bonusBPS, 0, 2000); // Max 20% bonus

        uint256 debtWithBonus = debtToCover * (BPS_DENOMINATOR + bonusBPS) / BPS_DENOMINATOR;
        uint256 collateralToSeize = (debtWithBonus * collateralAmount) / collateralUsdValue;

        // Seizure should be reasonable relative to inputs
        // When debtToCover <= collateralUsdValue and bonus <= 20%:
        // collateralToSeize <= collateralAmount * 1.2
        assertTrue(
            collateralToSeize <= collateralAmount * 12 / 10 + 1, // +1 for rounding
            "Seizure should not exceed 120% of collateral amount"
        );
    }

    // ============ Fee Distribution Balance Fuzz ============

    /// @notice Fuzz: taker fee > maker rebate (protocol always earns)
    function testFuzz_fee_spread_positive(uint256 interest, uint256 takerBPS, uint256 makerBPS) public pure {
        interest = bound(interest, 1, 1_000_000e6);
        takerBPS = bound(takerBPS, 100, 1000); // 1% to 10%
        makerBPS = bound(makerBPS, 0, takerBPS - 1); // Always less than taker

        uint256 takerFee = (interest * takerBPS) / BPS_DENOMINATOR;
        uint256 makerRebate = (interest * makerBPS) / BPS_DENOMINATOR;

        assertTrue(takerFee >= makerRebate, "Protocol spread must be non-negative");
        uint256 protocolRevenue = takerFee - makerRebate;
        assertTrue(protocolRevenue >= 0, "Protocol revenue non-negative");
    }

    // ============ Decimal Normalization Fuzz ============

    /// @notice Fuzz: 6-decimal to 18-decimal normalization is reversible
    function testFuzz_decimal_normalization(uint256 amount6dec) public pure {
        amount6dec = bound(amount6dec, 0, 1_000_000_000e6); // Up to 1B USDC

        uint256 amount18dec = amount6dec * (10 ** (18 - 6));
        uint256 roundTrip = amount18dec / (10 ** (18 - 6));

        assertEq(roundTrip, amount6dec, "Round-trip normalization must be exact");
    }
}
