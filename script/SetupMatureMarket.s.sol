// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ISettlement} from "../src/interfaces/ISettlement.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SetupMatureMarket
/// @notice Foundry script to create a settled lend position on Anvil for E2E withdraw testing.
/// @dev Run against a local Anvil node after deploying all contracts via run-all.sh.
///
/// Environment variables:
///   SETTLEMENT_PROXY   - Settlement proxy address
///   TREASURY_ADDRESS   - Treasury address
///   USDC_ADDRESS       - Mock USDC token address
///   DEPLOYER_PK        - Deployer private key (has MINTER_ROLE on MockToken)
///   LENDER_PK          - Lender (backend operator) private key
///   BORROWER_PK        - Borrower private key
///   SETTLEMENT_OP_PK   - Settlement operator private key
contract SetupMatureMarket is Script {
    uint256 constant MATCHED_AMOUNT = 1000e6; // 1000 USDC (6 decimals)
    uint256 constant DEPOSIT_AMOUNT = 1500e6; // extra buffer
    uint256 constant RATE = 500; // 5% APR in basis points
    uint256 constant MATURITY_OFFSET = 120; // 2 minutes from now

    function run() external {
        // Read addresses from environment
        address settlement = vm.envAddress("SETTLEMENT_PROXY");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");

        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        uint256 lenderPk = vm.envUint("LENDER_PK");
        uint256 borrowerPk = vm.envUint("BORROWER_PK");
        uint256 settlementOpPk = vm.envUint("SETTLEMENT_OP_PK");

        address lender = vm.addr(lenderPk);
        address borrower = vm.addr(borrowerPk);

        uint256 maturity = block.timestamp + MATURITY_OFFSET;

        // Compute marketId matching backend's computeMarketId + uuidToBytes32:
        // Take first 16 bytes of keccak256(abi.encode(loanToken, maturity)), zero-pad lower 16 bytes.
        bytes32 fullHash = keccak256(abi.encode(usdc, maturity));
        bytes32 marketId = fullHash & bytes32(uint256(type(uint128).max) << 128);

        console.log("=== SetupMatureMarket ===");
        console.log("Settlement:", settlement);
        console.log("Treasury:", treasury);
        console.log("USDC:", usdc);
        console.log("Lender:", lender);
        console.log("Borrower:", borrower);
        console.log("Maturity:", maturity);
        console.log("MarketId (bytes32):");
        console.logBytes32(marketId);

        // --- Step 1: Deployer mints USDC to lender and borrower ---
        vm.startBroadcast(deployerPk);
        // MockToken.mint(address,uint256) — deployer has MINTER_ROLE
        (bool ok,) = usdc.call(abi.encodeWithSignature("mint(address,uint256)", lender, DEPOSIT_AMOUNT));
        require(ok, "Mint to lender failed");
        (ok,) = usdc.call(abi.encodeWithSignature("mint(address,uint256)", borrower, DEPOSIT_AMOUNT));
        require(ok, "Mint to borrower failed");
        vm.stopBroadcast();

        // --- Step 2: Lender approves Treasury and deposits ---
        vm.startBroadcast(lenderPk);
        IERC20(usdc).approve(treasury, DEPOSIT_AMOUNT);
        // Treasury.deposit(address,uint256)
        (ok,) = treasury.call(abi.encodeWithSignature("deposit(address,uint256)", usdc, DEPOSIT_AMOUNT));
        require(ok, "Lender deposit failed");
        vm.stopBroadcast();

        // --- Step 3: Borrower approves Treasury and deposits ---
        vm.startBroadcast(borrowerPk);
        IERC20(usdc).approve(treasury, DEPOSIT_AMOUNT);
        (ok,) = treasury.call(abi.encodeWithSignature("deposit(address,uint256)", usdc, DEPOSIT_AMOUNT));
        require(ok, "Borrower deposit failed");
        vm.stopBroadcast();

        // --- Step 4: Settlement operator settles the match ---
        ISettlement.MatchData memory matchData = ISettlement.MatchData({
            matchId: keccak256("e2e-mature-market-test-v1"),
            marketId: marketId,
            lendOrderId: keccak256("e2e-lend-order-1"),
            borrowOrderId: keccak256("e2e-borrow-order-1"),
            lender: lender,
            borrower: borrower,
            matchedAmount: MATCHED_AMOUNT,
            rate: RATE,
            loanToken: usdc,
            maturity: maturity,
            timestamp: block.timestamp,
            borrowerIsTaker: true,
            lenderSettlementFee: 0,
            borrowerSettlementFee: 0,
            makerFeeAmount: 0,
            takerFeeAmount: 0
        });

        vm.startBroadcast(settlementOpPk);
        ISettlement(settlement).settleMatch(matchData);
        vm.stopBroadcast();

        // --- Output values needed by the shell script ---
        // With MATURITY_OFFSET=120 and day-count convention: rawDays = 120/86400 = 0, so interest=0, cbtAmount=principal
        uint256 cbtAmount = MATCHED_AMOUNT; // interest is 0 for sub-day maturity
        console.log("=== OUTPUT ===");
        console.log("MATURITY=%d", maturity);
        console.log("MATCHED_AMOUNT=%d", MATCHED_AMOUNT);
        console.log("CBT_AMOUNT=%d", cbtAmount);
        console.log("LENDER=%s", lender);
        console.log("BORROWER=%s", borrower);
    }
}
