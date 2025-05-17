//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployLending} from "../../script/DeployLending.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Lending} from "../../src/Lending.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FaucetTokens} from "../../src/faucet/FaucetTokens.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.t.sol";

contract LendingTest is Test {
    HelperConfig public helperConfig;
    Lending public lending;
    FaucetTokens public faucetContract;

    address public weth;
    address public wbtc;
    address public dai;
    address public wethUsdPriceFeed;
    address public wbtcUsdPriceFeed;
    address public daiUsdPriceFeed;
    address public faucet;

    address public obofte = makeAddr("obofte");
    address public debtor = makeAddr("debtor");
    address public liquidator = makeAddr("liquidator");

    // Constants for test amounts
    uint256 public constant DEPOSIT_AMOUNT = 1 ether;
    uint256 public constant BORROW_AMOUNT = 0.5 ether; // borrowing less than deposit to maintain health factor
    uint256 public constant WETH_FAUCET_AMOUNT = 2 ether;
    uint256 public constant WBTC_FAUCET_AMOUNT = 1 ether;
    uint256 public constant DAI_FAUCET_AMOUNT = 10_000 ether;

    uint256 public constant ETH_USD_PRICE = 2000e18; //$2000/ETH
    uint256 public constant BTC_USD_PRICE = 100_000e18; //$100,000/BTC
    uint256 public constant DAI_USD_PRICE = 1e18; //$1/DAI --> stablecoin

    struct LoanSnapshot {
        bytes32 id;
        uint256 amount;
        uint256 interest;
        uint256 startTime;
        Lending.LoanStatus status;
        uint256 collateralAmount;
        address borrowToken;
        address collateralToken;
    }

    // Events we expect from Lending.sol
    event CollateralDeposited(address indexed account, address indexed tokenAddress, uint256 amount);
    event CollateralRedeemed(address indexed account, address indexed tokenAddress, uint256 amount);
    event LoanCreated(
        address indexed account,
        address indexed borrowToken,
        address indexed collateralToken,
        uint256 borrowAmount,
        uint256 collateralAmount
    );
    event LoanRepaid(
        address indexed account, address indexed borrowToken, address indexed collateralToken, uint256 amount
    );
    event LoanLiquidated(
        address indexed account,
        address indexed borrowToken,
        address indexed collateralToken,
        uint256 borrowAmount,
        uint256 collateralAmount,
        address liquidator
    );

    function setUp() public {
        DeployLending deployer = new DeployLending();
        (lending, helperConfig) = deployer.run();

        (weth, wbtc, dai, wethUsdPriceFeed, wbtcUsdPriceFeed, daiUsdPriceFeed, faucet,) =
            helperConfig.activeNetworkConfig();

        faucetContract = FaucetTokens(faucet);

        // Fund the lending contract with initial liquidity using deal
        deal(weth, address(lending), 1000 ether); // 1000 WETH
        deal(wbtc, address(lending), 1000 ether); // 1000 WBTC
        deal(dai, address(lending), 1_000_000 ether); // 1_000_000 DAI
    }

    //////////////////////////
    //   Constructor test   //
    //////////////////////////
    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        address[] memory tokens = new address[](2);
        address[] memory priceFeeds = new address[](3);
        tokens[0] = weth;
        tokens[1] = wbtc;
        priceFeeds[0] = wethUsdPriceFeed;
        priceFeeds[1] = wbtcUsdPriceFeed;
        priceFeeds[2] = daiUsdPriceFeed;

        vm.expectRevert(
            abi.encodeWithSelector(
                Lending.Lending__TokenAddressesArrayAndPriceFeedAddressesArrayMustBeSameLength.selector
            )
        );
        new Lending(tokens, priceFeeds);
    }
    //////////////////////////
    //   PriceFeed Test     //
    //////////////////////////

    function testPriceFeed() public view {
        // Get the price of WETH in USD
        uint256 wethPrice = lending.getUSDValue(weth, 1e18);
        // Get the price of WBTC in USD
        uint256 wbtcPrice = lending.getUSDValue(wbtc, 1e18);
        // Get the price of DAI in USD
        uint256 daiPrice = lending.getUSDValue(dai, 1e18);

        console.log("WETH price in USD: ", wethPrice);
        console.log("WBTC price in USD: ", wbtcPrice);
        console.log("DAI price in USD: ", daiPrice);

        // Assert the prices are correct
        assertEq(wethPrice, ETH_USD_PRICE, "Incorrect WETH price");
        assertEq(wbtcPrice, BTC_USD_PRICE, "Incorrect WBTC price");
        assertEq(daiPrice, DAI_USD_PRICE, "Incorrect DAI price");
    }

    function testGetTokenAmountFromUsd() public {
        // Test cases:
        // 1. Convert $2000 to WETH (should get 1 WETH since price is $2000/WETH)
        uint256 usdAmountForWeth = 2000e18; // $2000 in wei
        uint256 wethAmount = lending.getTokenAmountFromUsd(weth, usdAmountForWeth);
        assertEq(wethAmount, 1 ether, "Should get 1 WETH for $2000");
        console.log("Amount of WETH for $2000: ", wethAmount);

        // 2. Convert $100000 to WBTC (should get 1 WBTC since price is $100000/WBTC)
        uint256 usdAmountForBtc = 100000e18; // $100000 in wei
        uint256 wbtcAmount = lending.getTokenAmountFromUsd(wbtc, usdAmountForBtc);
        assertEq(wbtcAmount, 1 ether, "Should get 1 WBTC for $100000");

        // 3. Convert $1000 to DAI (should get 1000 DAI since price is $1/DAI)
        uint256 usdAmountForDai = 1000e18; // $1000 in wei
        uint256 daiAmount = lending.getTokenAmountFromUsd(dai, usdAmountForDai);
        assertEq(daiAmount, 1000 ether, "Should get 1000 DAI for $1000");

        // Test smaller amounts
        // 4. Convert $1000 to WETH (should get 0.5 WETH)
        usdAmountForWeth = 1000 ether; // $1000 in wei
        wethAmount = lending.getTokenAmountFromUsd(weth, usdAmountForWeth);
        assertEq(wethAmount, 0.5 ether, "Should get 0.5 WETH for $1000");
    }

    //////////////////////////
    //      Modifiers       //
    //////////////////////////

    modifier funded(address user) {
        deal(weth, user, WETH_FAUCET_AMOUNT);
        deal(wbtc, user, WBTC_FAUCET_AMOUNT);
        deal(dai, user, DAI_FAUCET_AMOUNT);
        _;
    }

    modifier depositCollateral(address user, address token, uint256 amount) {
        vm.startPrank(user);
        // user approve the lending contract to withdraw the deposit amount from his wallet
        IERC20(token).approve(address(lending), amount);
        lending.depositCollateral(token, amount);
        vm.stopPrank();
        _;
    }

    //////////////////////////
    // Deposit Tests        //
    //////////////////////////

    function testProtocolReceivesFaucet() public {
        // Check if the lending contract received the tokens from the faucet
        uint256 wethBalance = IERC20(weth).balanceOf(address(lending));
        uint256 wbtcBalance = IERC20(wbtc).balanceOf(address(lending));
        uint256 daiBalance = IERC20(dai).balanceOf(address(lending));

        assertEq(wethBalance, 1000e18, "Lending contract should receive 1000 WETH from faucet");
        assertEq(wbtcBalance, 1000e18, "Lending contract should receive 1000 WBTC from faucet");
        assertEq(daiBalance, 1000000e18, "Lending contract should receive 1_000_000 DAI from faucet");
    }

    function testDepositCollateral() public funded(obofte) depositCollateral(obofte, weth, DEPOSIT_AMOUNT) {
        // Get user's token balance and contract's token balance
        uint256 userTokenBalance = IERC20(weth).balanceOf(obofte);

        // Get free collateral balance (needs to be called as the user)
        vm.startPrank(obofte);
        uint256 userDepositedBalance = lending.getFreeCollateral(weth);
        vm.stopPrank();

        // Assert the deposit was successful
        assertEq(userDepositedBalance, DEPOSIT_AMOUNT, "Incorrect deposited collateral amount");
        assertEq(userTokenBalance, WETH_FAUCET_AMOUNT - DEPOSIT_AMOUNT, "Incorrect remaining user balance");
    }

    function testRevertsWhenDepositZero() public funded(obofte) {
        vm.startPrank(obofte);
        vm.expectRevert(Lending.Lending__NeedsMoreThanZero.selector);
        lending.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnsupportedTokenDeposit() public funded(obofte) {
        address unsupportedToken = makeAddr("unsupportedToken");
        vm.startPrank(obofte);
        vm.expectRevert(abi.encodeWithSelector(Lending.Lending__UnsupportedToken.selector, unsupportedToken));
        lending.depositCollateral(unsupportedToken, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    //////////////////////////
    // Borrow Tests         //
    //////////////////////////

    function testUserCanBorrowToken() public funded(obofte) {
        // Initial setup and balance tracking --> user gets faucet tokens
        uint256 startingUserDaiBalance = IERC20(dai).balanceOf(obofte);
        uint256 startingUserWethBalance = IERC20(weth).balanceOf(obofte);
        uint256 startingProtocolDaiBalance = IERC20(dai).balanceOf(address(lending));

        uint256 borrowAmount = 500e18; // Borrowing 500 DAI

        vm.startPrank(obofte);

        // 1. Deposit WETH as collateral
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        vm.expectEmit(true, true, true, true, address(lending));
        emit CollateralDeposited(obofte, weth, DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);

        // 2. Borrow DAI against the WETH collateral
        vm.expectEmit(true, true, true, true, address(lending));
        emit LoanCreated(obofte, dai, weth, borrowAmount, DEPOSIT_AMOUNT);
        lending.borrow(dai, weth, borrowAmount, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // 3. Verify loan details
        (uint256 loanAmount, uint256 collateralAmount, uint256 interestDue, Lending.LoanStatus status) =
            lending.getLoanDetails(obofte, dai, weth);

        // 4. Assert loan state
        assertEq(loanAmount, borrowAmount, "Incorrect loan amount");
        assertEq(collateralAmount, DEPOSIT_AMOUNT, "Incorrect collateral amount");
        assertEq(uint8(status), uint8(Lending.LoanStatus.ACTIVE), "Loan should be active");
        assertEq(interestDue, 0, "Interest should start at 0");

        // 5. Verify token transfers
        assertEq(
            IERC20(dai).balanceOf(obofte), startingUserDaiBalance + borrowAmount, "User should receive borrowed DAI"
        );
        assertEq(
            IERC20(weth).balanceOf(obofte),
            startingUserWethBalance - DEPOSIT_AMOUNT,
            "User's WETH balance should decrease by deposit amount"
        );
        assertEq(
            IERC20(dai).balanceOf(address(lending)),
            startingProtocolDaiBalance - borrowAmount,
            "Protocol's DAI balance should decrease by borrowed amount"
        );
    }

    function testRevertsWhenBorrowingMoreThanCollateralValue() public funded(obofte) {
        // First deposit collateral
        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        //user deposits collateral worth $2000
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);

        // user tries to borrow dai worth $500 but with 3WETH as collateral but he only has 1WETH
        uint256 borrowAmount = 500e18;
        vm.expectRevert(abi.encodeWithSelector(Lending.Lending__InsufficientCollateralForLoan.selector, DEPOSIT_AMOUNT));
        lending.borrow(dai, weth, borrowAmount, 3e18);
        vm.stopPrank();
    }

    function testRevertsWhenBorrowingSameToken() public funded(obofte) {
        // First deposit collateral
        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);

        // Try to borrow the same token as collateral
        vm.expectRevert(Lending.Lending__SameTokenNotAllowed.selector);
        lending.borrow(weth, weth, 0.5 ether, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    //////////////////////////
    // Repayment Tests      //
    //////////////////////////

    function testUserCanRepayLoan() public funded(obofte) {
        // Constants
        uint256 BORROW_DAI_AMOUNT = 500 ether; // 500 DAI
        uint256 TIME_ELAPSED = 60 days; // 2 months for interest accrual

        // -------- Setup: Deposit collateral and borrow --------
        vm.startPrank(obofte);

        // 1. Deposit WETH as collateral
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);

        // 2. Borrow DAI against WETH
        lending.borrow(dai, weth, BORROW_DAI_AMOUNT, DEPOSIT_AMOUNT);

        // -------- Track initial balances --------
        // 3. Store balances before repayment for verification
        uint256 userDaiBeforeRepay = IERC20(dai).balanceOf(obofte);
        uint256 protocolDaiBeforeRepay = IERC20(dai).balanceOf(address(lending));

        // -------- Simulate time passing for interest accrual --------
        // 4. Move time forward and calculate total due with interest
        vm.warp(block.timestamp + TIME_ELAPSED);
        (,, uint256 interestAccrued,) = lending.getLoanDetails(obofte, dai, weth);
        uint256 totalDue = BORROW_DAI_AMOUNT + interestAccrued;

        // -------- Execute repayment --------
        // 5. Approve and repay the full loan
        IERC20(dai).approve(address(lending), totalDue);

        // 6. Verify repayment event
        vm.expectEmit(true, true, true, true, address(lending));
        emit LoanRepaid(obofte, dai, weth, totalDue);

        // 7. Execute repayment
        lending.repay(dai, weth, totalDue);
        vm.stopPrank();

        // -------- Verify final state --------
        // 8. Check loan state is properly cleared
        (uint256 loanAmount, uint256 collateralAmount, uint256 interestDue, Lending.LoanStatus status) =
            lending.getLoanDetails(obofte, dai, weth);

        assertEq(loanAmount, 0, "Loan amount should be zero after repayment");
        assertEq(collateralAmount, 0, "Collateral should be fully released");
        assertEq(uint8(status), uint8(Lending.LoanStatus.REPAID), "Loan status should be REPAID");
        assertEq(interestDue, 0, "No interest should remain after repayment");

        // 9. Verify token transfers are correct
        assertEq(
            IERC20(dai).balanceOf(obofte),
            userDaiBeforeRepay - totalDue,
            "User's DAI balance should decrease by total repayment amount"
        );
        assertEq(
            IERC20(dai).balanceOf(address(lending)),
            protocolDaiBeforeRepay + totalDue,
            "Protocol's DAI balance should increase by total repayment amount"
        );
    }

    function testRevertsWhenRepayingWithInsufficientBalance() public funded(obofte) {
        uint256 borrowAmount = 500 ether; //$500 DAI
        uint256 timeElapsed = 30 days;

        // -------- Setup: Create a loan --------
        vm.startPrank(obofte);

        // 1. Setup collateral and borrow
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);
        lending.borrow(dai, weth, borrowAmount, DEPOSIT_AMOUNT);

        // 2. Simulate time passing for interest accrual
        vm.warp(block.timestamp + timeElapsed);

        // 3. Get total repayment amount including interest
        (,, uint256 interestAccrued,) = lending.getLoanDetails(obofte, dai, weth);
        uint256 totalDue = borrowAmount + interestAccrued;

        // 4. Simulate user spending all their DAI
        IERC20(dai).transfer(address(1), IERC20(dai).balanceOf(obofte));
        uint256 userBalance = IERC20(dai).balanceOf(obofte);

        // 5. Try to repay with insufficient balance
        IERC20(dai).approve(address(lending), totalDue);
        vm.expectRevert(
            abi.encodeWithSelector(Lending.Lending__InsufficientTokenBalanceToRepayLoan.selector, userBalance, totalDue)
        );
        lending.repay(dai, weth, totalDue);
        vm.stopPrank();
    }

    //////////////////////////
    // Liquidation Tests    //
    //////////////////////////

    function testLiquidation() public funded(obofte) {
        // -------- Setup: Create a risky loan position --------
        uint256 borrowAmount = 500e18; // Borrow 500 DAI ($500)
        uint256 userDeposit = 0.4 ether; // 0.4 WETH ($800) as collateral - intentionally close to liquidation threshold

        // 1. Setup initial loan
        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), userDeposit);
        lending.depositCollateral(weth, userDeposit);
        lending.borrow(dai, weth, borrowAmount, userDeposit);
        vm.stopPrank();

        // 2. Advance time for interest accrual and update Oracle timestamp
        uint256 timeElapsed = 30 days;
        vm.warp(block.timestamp + timeElapsed);

        // 3. Get loan details before liquidation and store initial balances
        (uint256 loanAmount,, uint256 interestAccrued,) = lending.getLoanDetails(obofte, dai, weth);
        uint256 totalDebt = loanAmount + interestAccrued;
        // Store protocol's DAI and WETH balance before liquidation
        uint256 protocolDaiBalanceBefore = IERC20(dai).balanceOf(address(lending));
        uint256 protocolWethBalanceBefore = IERC20(weth).balanceOf(address(lending));

        // 4. Update price feeds for all tokens
        uint80 roundId = 1;
        uint256 startedAt = block.timestamp;
        uint256 updatedAt = block.timestamp;
        uint80 answeredInRound = 1;

        // WETH price crash from $2000 to $1500
        vm.mockCall(
            wethUsdPriceFeed,
            abi.encodeWithSelector(MockV3Aggregator.latestRoundData.selector),
            abi.encode(roundId, 1500e8, startedAt, updatedAt, answeredInRound)
        );
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(1500e8);

        // Keep DAI price stable at $1
        vm.mockCall(
            daiUsdPriceFeed,
            abi.encodeWithSelector(MockV3Aggregator.latestRoundData.selector),
            abi.encode(roundId, 1e8, startedAt, updatedAt, answeredInRound)
        );
        MockV3Aggregator(daiUsdPriceFeed).updateAnswer(1e8);

        // Verify position is now liquidatable
        uint256 healthFactor = lending.getUserLoanHealthFactor(obofte, dai, weth);
        assertTrue(healthFactor < 1e18, "Position should be liquidatable");

        // 5. Prepare liquidator
        vm.startPrank(liquidator);

        // Give liquidator enough DAI and cover debtors loan
        deal(dai, liquidator, totalDebt * 2);
        IERC20(dai).approve(address(lending), totalDebt * 2);

        // Calculate liquidation details:
        // 1. Convert debt amount to WETH (this is what liquidator should receive as base amount)
        uint256 debtInWeth = lending.getTokenAmountFromUsd(weth, lending.getUSDValue(dai, totalDebt));
        // 2. Calculate 10% bonus of the locked collateral
        uint256 liquidatorBonus = (userDeposit * 10) / 100;
        // 3. Total WETH the liquidator should receive
        uint256 expectedLiquidatorReward = debtInWeth + liquidatorBonus;

        // 6. Expect liquidation event with correct parameters
        vm.expectEmit(true, true, true, true, address(lending));
        emit LoanLiquidated(obofte, dai, weth, totalDebt, expectedLiquidatorReward, liquidator);

        // 7. Execute liquidation
        lending.liquidate(obofte, dai, weth);
        vm.stopPrank();

        // 8. Verify loan state after liquidation
        (uint256 finalLoanAmount, uint256 finalCollateral,, Lending.LoanStatus status) =
            lending.getLoanDetails(obofte, dai, weth);

        assertEq(finalLoanAmount, 0, "Loan amount should be cleared");
        assertEq(finalCollateral, 0, "Collateral should be cleared");
        assertEq(uint8(status), uint8(Lending.LoanStatus.LIQUIDATED), "Loan status should be LIQUIDATED");

        // 9. Verify token balances
        // Liquidator gets WETH equivalent to debt they paid + 10% bonus
        assertEq(
            IERC20(weth).balanceOf(liquidator),
            expectedLiquidatorReward,
            "Liquidator should receive WETH worth their payment + bonus"
        );
        // Protocol keeps remaining collateral as profit
        assertEq(
            IERC20(weth).balanceOf(address(lending)),
            protocolWethBalanceBefore - expectedLiquidatorReward,
            "Protocol WETH balance after liquidation should be original - liquidator reward"
        );
        // Protocol receives full debt repayment
        assertEq(
            IERC20(dai).balanceOf(address(lending)),
            protocolDaiBalanceBefore + totalDebt,
            "Protocol DAI balance after liquidation should increase by debt amount"
        );
    }

    function testRevertsWhenLiquidatingHealthyPosition() public funded(obofte) funded(liquidator) {
        uint256 borrowAmount = 500e18; // Borrow 500 DAI against 1 ETH ($2000)

        // Setup healthy position
        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT); // use entire 1 WETH ($2000) as collateral
        lending.borrow(dai, weth, borrowAmount, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Liquidator tries to liquidate healthy position
        vm.startPrank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(
                Lending.Lending__AccountHealthFactorGreaterThanOrEqualToMinimumRequired.selector,
                3.2e18 // (2000 * 0.8) / 500 = 3.2, scaled by 1e18
            )
        );
        lending.liquidate(obofte, dai, weth);
        vm.stopPrank();
    }

    //////////////////////////
    // Health Factor Tests  //
    //////////////////////////

    function testHealthFactorCalculation() public funded(obofte) {
        uint256 borrowAmount = 500e18; // Borrow 500 DAI --> $500

        uint256 initialHealthFactor = lending.getUserLoanHealthFactor(obofte, dai, weth);
        console.log("obofte initial health factor: ", initialHealthFactor);
        // Setup a loan
        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT); //obofte deposits 1 ETH --> $2000
        lending.borrow(dai, weth, borrowAmount, DEPOSIT_AMOUNT); //obofte borrows 500 DAI --> $500 and uses his entire 1 WETH ($2000) as collateral
        uint256 healthFactor = lending.getLoanHealthFactor(dai, weth);
        vm.stopPrank();

        console.log("obofte health factor: ", healthFactor);

        // Expected HF = (2000 * 0.8) / 500 = 3.2e18
        assertEq(healthFactor, 3.2e18, "Incorrect health factor calculation");

        // Test health factor changes with price
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(1000e8); // ETH price drops to $1000
        uint256 newHealthFactor = lending.getUserLoanHealthFactor(obofte, dai, weth);
        // New HF = (1000 * 0.8) / 500 = 1.6e18
        assertEq(newHealthFactor, 1.6e18, "Health factor should decrease with price drop");
    }

    //////////////////////////
    // Withdrawal Tests     //
    //////////////////////////

    function testWithdrawCollateral() public funded(obofte) {
        // First user gets 2WETH from faucet, deposits 1 WETH as collateral, then withdraws 0.5 WETH --> user should have a balance of 1.5 WETH
        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);

        uint256 withdrawAmount = 0.5 ether;
        vm.expectEmit(true, true, true, true, address(lending));
        emit CollateralRedeemed(obofte, weth, withdrawAmount);
        lending.withdrawCollateral(weth, withdrawAmount);
        vm.stopPrank();

        assertEq(IERC20(weth).balanceOf(obofte), 1.5 ether, "Incorrect balance after withdrawal");
    }

    function testRevertsWhenWithdrawingTooMuch() public funded(obofte) {
        uint256 borrowAmount = 500e18; // Borrow 500 DAI

        // Setup: user deposits 1WETH ($2000) collateral as collateral for a $500 loan
        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);
        lending.borrow(dai, weth, borrowAmount, DEPOSIT_AMOUNT);

        // Trying to withdraw any amount should revert because the user used the total amount of collateral to back the loan and have a balance of 0
        vm.expectRevert(
            abi.encodeWithSelector(
                Lending.Lending__InsufficientTokenBalance.selector,
                0 // Free collateral available
            )
        );
        lending.withdrawCollateral(weth, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function testInterestCalculation() public funded(obofte) {
        uint256 borrowAmount = 500e18; // Borrow 500 DAI
        uint256 timeElapsed = 365 days; // 1 year

        // Setup loan
        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);
        lending.borrow(dai, weth, borrowAmount, DEPOSIT_AMOUNT);

        // Advance time
        vm.warp(block.timestamp + timeElapsed);

        // Get accrued interest
        (,, uint256 interestAccrued,) = lending.getLoanDetails(obofte, dai, weth);

        // Expected interest = principal * rate * time / (SECONDS_PER_YEAR * INTEREST_PRECISION)
        // 500e18 * 3 * 31536000 / (31536000 * 100) = 15e18 DAI
        assertEq(interestAccrued, 15e18, "Interest calculation incorrect");
        vm.stopPrank();
    }

    function testAddAndFreeCollateral() public funded(obofte) {
        uint256 borrowAmount = 500e18; // Borrow 500 DAI
        uint256 initialDeposit = 0.5 ether; // Initial 0.5 WETH deposit
        uint256 additionalCollateral = 0.25 ether; // Add 0.25 WETH more

        // Setup initial loan
        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT * 2); // Approve enough for both initial and additional

        // First, deposit both initial and additional collateral
        lending.depositCollateral(weth, initialDeposit + additionalCollateral);

        // Setup loan with initial collateral
        lending.borrow(dai, weth, borrowAmount, initialDeposit);

        // Add more collateral to the loan
        lending.addCollateralToLoan(dai, weth, additionalCollateral);

        // Verify collateral was added
        (, uint256 collateralAmount,,) = lending.getLoanDetails(obofte, dai, weth);
        assertEq(collateralAmount, initialDeposit + additionalCollateral, "Collateral not added correctly");

        // Free some collateral
        lending.freeCollateralFromLoan(dai, weth, additionalCollateral);

        // Verify collateral was freed
        (, uint256 newCollateralAmount,,) = lending.getLoanDetails(obofte, dai, weth);
        assertEq(newCollateralAmount, initialDeposit, "Collateral not freed correctly");
        vm.stopPrank();
    }

    function testRevertsWhenFreeTooMuchCollateral() public funded(obofte) {
        uint256 borrowAmount = 500e18; // Borrow 500 DAI
        uint256 collateralAmount = 0.5 ether; // 0.5 WETH as collateral

        // Setup loan
        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, collateralAmount);
        lending.borrow(dai, weth, borrowAmount, collateralAmount);

        // Try to free more collateral than the minimum required for the loan
        // For a $500 DAI loan at 80% LTV, we need $625 worth of collateral
        // With WETH at $2000/ETH, that's 0.3125 ETH minimum required
        // (500 * 100/80 = 625 USD needed, 625/2000 = 0.3125 WETH)
        uint256 minimumRequired = 0.3125 ether;
        vm.expectRevert(
            abi.encodeWithSelector(Lending.Lending__NotUpToMinimumCollateralRequiredForLoan.selector, minimumRequired)
        );
        lending.freeCollateralFromLoan(dai, weth, 0.2 ether);
        vm.stopPrank();
    }

    function testGetAllowedTokens() public {
        address[] memory allowedTokens = lending.getAllowedTokens();
        assertEq(allowedTokens.length, 3, "Should have 3 allowed tokens");
        assertEq(allowedTokens[0], weth, "WETH should be allowed");
        assertEq(allowedTokens[1], wbtc, "WBTC should be allowed");
        assertEq(allowedTokens[2], dai, "DAI should be allowed");
    }

    function testGetUserLoansWithStatus() public funded(obofte) {
        // Setup first loan
        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);
        lending.borrow(dai, weth, 500e18, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Get active loans
        (
            address[] memory borrowTokens,
            address[] memory collateralTokens,
            uint256[] memory amounts,
            uint256[] memory collateralAmounts
        ) = lending.getUserLoansWithStatus(obofte, Lending.LoanStatus.ACTIVE);

        // Verify loan details
        assertEq(borrowTokens.length, 1, "Should have 1 active loan");
        assertEq(borrowTokens[0], dai, "Borrow token should be DAI");
        assertEq(collateralTokens[0], weth, "Collateral token should be WETH");
        assertEq(amounts[0], 500e18, "Borrow amount should be 500 DAI");
        assertEq(collateralAmounts[0], DEPOSIT_AMOUNT, "Collateral amount should be 1 WETH");
    }

    function testLoanIdAndStorageWhenBorrowing() public funded(obofte) {
        // Setup
        uint256 borrowAmount = 500e18; // 500 DAI

        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);

        // Borrow and capture event
        vm.expectEmit(true, true, true, true, address(lending));
        emit LoanCreated(obofte, dai, weth, borrowAmount, DEPOSIT_AMOUNT);
        lending.borrow(dai, weth, borrowAmount, DEPOSIT_AMOUNT);

        // Get loan details to verify storage
        (bytes32[] memory loanIds) = lending.getUserLoanIds(obofte);
        assertEq(loanIds.length, 1, "User should have 1 loan");

        Lending.Loan memory loan = lending.getLoanById(loanIds[0]);
        assertEq(loan.amount, borrowAmount, "Loan amount mismatch");
        assertEq(loan.collateralAmount, DEPOSIT_AMOUNT, "Collateral amount mismatch");
        assertEq(loan.borrowToken, dai, "Borrow token mismatch");
        assertEq(loan.collateralToken, weth, "Collateral token mismatch");
        assertEq(uint8(loan.status), uint8(Lending.LoanStatus.ACTIVE), "Loan status should be ACTIVE");
        assertEq(loan.id, loanIds[0], "Loan ID mismatch");

        vm.stopPrank();
    }

    function testLoanLifecycle() public funded(obofte) {
        // Constants
        uint256 borrowAmount = 500e18; // 500 DAI
        uint256 timeElapsed = 60 days;

        vm.startPrank(obofte);

        // 1. Deposit WETH as collateral
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);

        // 2. Borrow DAI against WETH
        vm.expectEmit(true, true, true, true, address(lending));
        emit LoanCreated(obofte, dai, weth, borrowAmount, DEPOSIT_AMOUNT);
        lending.borrow(dai, weth, borrowAmount, DEPOSIT_AMOUNT);

        // 3. Get loan ID and initial state
        bytes32[] memory loanIds = lending.getUserLoanIds(obofte);
        assertEq(loanIds.length, 1, "Should have one loan");

        // 4. Get initial loan state
        (uint256 initialAmount, uint256 initialCollateral, uint256 initialInterest, Lending.LoanStatus initialStatus) =
            lending.getLoanDetails(obofte, dai, weth);

        assertEq(initialAmount, borrowAmount, "Initial loan amount mismatch");
        assertEq(initialCollateral, DEPOSIT_AMOUNT, "Initial collateral mismatch");
        assertEq(initialInterest, 0, "Initial interest should be zero");
        assertEq(uint8(initialStatus), uint8(Lending.LoanStatus.ACTIVE), "Loan should be ACTIVE");

        // 5. Simulate time passing
        vm.warp(block.timestamp + timeElapsed);

        // 6. Get updated loan details with accrued interest
        (uint256 currentAmount, uint256 currentCollateral, uint256 currentInterest, Lending.LoanStatus currentStatus) =
            lending.getLoanDetails(obofte, dai, weth);

        uint256 totalDue = currentAmount + currentInterest;
        assertTrue(currentInterest > 0, "Interest should have accrued");

        // 7. Repay the loan
        IERC20(dai).approve(address(lending), totalDue);
        lending.repay(dai, weth, totalDue);

        // 8. Verify final loan state
        (uint256 finalAmount, uint256 finalCollateral, uint256 finalInterest, Lending.LoanStatus finalStatus) =
            lending.getLoanDetails(obofte, dai, weth);

        assertEq(uint8(finalStatus), uint8(Lending.LoanStatus.REPAID), "Loan should be REPAID");
        assertEq(finalAmount, 0, "Loan amount should be zero");
        assertEq(finalCollateral, 0, "Collateral should be zero");
        assertEq(finalInterest, 0, "Interest should be zero");

        vm.stopPrank();
    }

    function testMultipleLoansManagement() public funded(obofte) {
        // Setup multiple loans with different collaterals
        vm.startPrank(obofte);

        // Approve tokens
        IERC20(weth).approve(address(lending), type(uint256).max);
        IERC20(wbtc).approve(address(lending), type(uint256).max);

        // First loan: WETH collateral -> borrow DAI
        lending.depositCollateral(weth, 1 ether);
        lending.borrow(dai, weth, 500e18, 1 ether);

        // Second loan: WBTC collateral -> borrow DAI
        lending.depositCollateral(wbtc, 0.1 ether);
        lending.borrow(dai, wbtc, 1000e18, 0.1 ether);

        // Get all loans
        bytes32[] memory loanIds = lending.getUserLoanIds(obofte);
        assertEq(loanIds.length, 2, "Should have two loans");

        // Verify first loan
        Lending.Loan memory loan1 = lending.getLoanById(loanIds[0]);
        assertEq(loan1.collateralToken, weth, "First loan collateral should be WETH");
        assertEq(loan1.amount, 500e18, "First loan amount mismatch");

        // Verify second loan
        Lending.Loan memory loan2 = lending.getLoanById(loanIds[1]);
        assertEq(loan2.collateralToken, wbtc, "Second loan collateral should be WBTC");
        assertEq(loan2.amount, 1000e18, "Second loan amount mismatch");

        // Repay first loan
        uint256 loan1Due = loan1.amount + loan1.interest;
        IERC20(dai).approve(address(lending), loan1Due);
        lending.repay(dai, weth, loan1Due);

        // Verify first loan is repaid but second remains active
        loan1 = lending.getLoanById(loanIds[0]);
        loan2 = lending.getLoanById(loanIds[1]);

        assertEq(uint8(loan1.status), uint8(Lending.LoanStatus.REPAID), "First loan should be repaid");
        assertEq(uint8(loan2.status), uint8(Lending.LoanStatus.ACTIVE), "Second loan should remain active");

        vm.stopPrank();
    }

    function testLoanLifecycleWithNewStorage() public funded(obofte) {
        // Constants
        uint256 borrowAmount = 500e18; // 500 DAI
        uint256 timeElapsed = 60 days;

        vm.startPrank(obofte);

        // 1. Deposit WETH as collateral
        IERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);

        // 2. Borrow DAI against WETH
        vm.expectEmit(true, true, true, true, address(lending));
        emit LoanCreated(obofte, dai, weth, borrowAmount, DEPOSIT_AMOUNT);
        lending.borrow(dai, weth, borrowAmount, DEPOSIT_AMOUNT);

        // 3. Get loan ID and initial state
        bytes32[] memory loanIds = lending.getUserLoanIds(obofte);
        assertEq(loanIds.length, 1, "Should have one loan");

        // 4. Get initial loan state
        (uint256 initialAmount, uint256 initialCollateral, uint256 initialInterest, Lending.LoanStatus initialStatus) =
            lending.getLoanDetails(obofte, dai, weth);

        assertEq(initialAmount, borrowAmount, "Initial loan amount mismatch");
        assertEq(initialCollateral, DEPOSIT_AMOUNT, "Initial collateral mismatch");
        assertEq(initialInterest, 0, "Initial interest should be zero");
        assertEq(uint8(initialStatus), uint8(Lending.LoanStatus.ACTIVE), "Loan status should be ACTIVE");

        // 5. Simulate time passing
        vm.warp(block.timestamp + timeElapsed);

        // 6. Get updated loan details with accrued interest
        (uint256 currentAmount, uint256 currentCollateral, uint256 currentInterest, Lending.LoanStatus currentStatus) =
            lending.getLoanDetails(obofte, dai, weth);

        uint256 totalDue = currentAmount + currentInterest;
        assertTrue(currentInterest > 0, "Interest should have accrued");

        // 7. Repay the loan
        IERC20(dai).approve(address(lending), totalDue);
        lending.repay(dai, weth, totalDue);

        // 8. Verify final loan state
        (uint256 finalAmount, uint256 finalCollateral, uint256 finalInterest, Lending.LoanStatus finalStatus) =
            lending.getLoanDetails(obofte, dai, weth);

        assertEq(uint8(finalStatus), uint8(Lending.LoanStatus.REPAID), "Loan should be REPAID");
        assertEq(finalAmount, 0, "Loan amount should be zero");
        assertEq(finalCollateral, 0, "Collateral should be zero");
        assertEq(finalInterest, 0, "Interest should be zero");

        vm.stopPrank();
    }

    function testMultipleLoansTracking() public funded(obofte) {
        vm.startPrank(obofte);

        // Setup maximum approvals
        IERC20(weth).approve(address(lending), type(uint256).max);
        IERC20(wbtc).approve(address(lending), type(uint256).max);

        // Create two loans
        // First loan: WETH collateral -> borrow DAI
        lending.depositCollateral(weth, 1 ether);
        lending.borrow(dai, weth, 500e18, 1 ether);

        // Second loan: WBTC collateral -> borrow DAI
        lending.depositCollateral(wbtc, 0.1 ether);
        lending.borrow(dai, wbtc, 1000e18, 0.1 ether);

        // Verify loan states
        (uint256 wethLoanAmount,,, Lending.LoanStatus wethLoanStatus) = lending.getLoanDetails(obofte, dai, weth);
        (uint256 wbtcLoanAmount,,, Lending.LoanStatus wbtcLoanStatus) = lending.getLoanDetails(obofte, dai, wbtc);

        assertEq(wethLoanAmount, 500e18, "WETH loan amount mismatch");
        assertEq(wbtcLoanAmount, 1000e18, "WBTC loan amount mismatch");
        assertEq(uint8(wethLoanStatus), uint8(Lending.LoanStatus.ACTIVE), "WETH loan should be active");
        assertEq(uint8(wbtcLoanStatus), uint8(Lending.LoanStatus.ACTIVE), "WBTC loan should be active");

        // Get loan details using getUserLoansWithStatus
        (
            address[] memory borrowTokens,
            address[] memory collateralTokens,
            uint256[] memory amounts,
            uint256[] memory collateralAmounts
        ) = lending.getUserLoansWithStatus(obofte, Lending.LoanStatus.ACTIVE);

        assertEq(borrowTokens.length, 2, "Should have two active loans");
        assertEq(collateralTokens.length, 2, "Should have two collateral tokens");

        // Repay first loan (WETH-backed)
        (,, uint256 wethLoanInterest,) = lending.getLoanDetails(obofte, dai, weth);
        uint256 wethLoanTotalDue = 500e18 + wethLoanInterest;

        IERC20(dai).approve(address(lending), wethLoanTotalDue);
        lending.repay(dai, weth, wethLoanTotalDue);

        // Verify updated loan states
        (,,, Lending.LoanStatus newWethLoanStatus) = lending.getLoanDetails(obofte, dai, weth);
        (,,, Lending.LoanStatus newWbtcLoanStatus) = lending.getLoanDetails(obofte, dai, wbtc);

        assertEq(uint8(newWethLoanStatus), uint8(Lending.LoanStatus.REPAID), "WETH loan should be repaid");
        assertEq(uint8(newWbtcLoanStatus), uint8(Lending.LoanStatus.ACTIVE), "WBTC loan should still be active");

        // Get active loans after repayment
        (borrowTokens, collateralTokens, amounts, collateralAmounts) =
            lending.getUserLoansWithStatus(obofte, Lending.LoanStatus.ACTIVE);

        assertEq(borrowTokens.length, 1, "Should have one active loan");
        assertEq(borrowTokens[0], dai, "Active loan should be DAI");
        assertEq(collateralTokens[0], wbtc, "Active loan collateral should be WBTC");

        vm.stopPrank();
    }

    function testMultipleLoansWithSameTokens() public funded(obofte) {
        vm.startPrank(obofte);
        IERC20(weth).approve(address(lending), type(uint256).max);

        // First loan: WETH -> DAI
        lending.depositCollateral(weth, 0.5 ether);
        lending.borrow(dai, weth, 500e18, 0.5 ether);

        // Get first loan details and verify status
        (uint256 firstLoanAmount,, uint256 firstLoanInterest, Lending.LoanStatus firstLoanStatus) =
            lending.getLoanDetails(obofte, dai, weth);
        assertEq(uint8(firstLoanStatus), uint8(Lending.LoanStatus.ACTIVE), "First loan should be active");

        bytes32[] memory loanIds = lending.getUserLoanIds(obofte);
        assertEq(loanIds.length, 1, "Should have one loan");
        bytes32 firstLoanId = loanIds[0];

        // Get total repayment amount including interest
        uint256 totalRepayAmount = firstLoanAmount + firstLoanInterest;

        // Repay first loan with principal + interest
        IERC20(dai).approve(address(lending), totalRepayAmount);
        lending.repay(dai, weth, totalRepayAmount);

        // Verify first loan is now repaid
        (,,, Lending.LoanStatus statusAfterRepay) = lending.getLoanDetails(obofte, dai, weth);
        assertEq(uint8(statusAfterRepay), uint8(Lending.LoanStatus.REPAID), "First loan should be repaid");

        // Take second loan with same tokens but different amounts
        lending.depositCollateral(weth, 0.7 ether);
        lending.borrow(dai, weth, 700e18, 0.7 ether);

        // Verify we now have two loans in history
        loanIds = lending.getUserLoanIds(obofte);
        assertEq(loanIds.length, 2, "Should have two loans in history");

        // Verify first loan is repaid and second is active
        Lending.Loan memory firstLoan = lending.getLoanById(firstLoanId);
        Lending.Loan memory secondLoan = lending.getLoanById(loanIds[1]);

        assertEq(uint8(firstLoan.status), uint8(Lending.LoanStatus.REPAID), "First loan should be repaid");
        assertEq(uint8(secondLoan.status), uint8(Lending.LoanStatus.ACTIVE), "Second loan should be active");
        assertEq(secondLoan.amount, 700e18, "Second loan amount should be 700 DAI");
        assertEq(secondLoan.collateralAmount, 0.7 ether, "Second loan collateral should be 0.7 WETH");

        // Verify active loans only shows the second loan
        (
            address[] memory borrowTokens,
            address[] memory collateralTokens,
            uint256[] memory amounts,
            uint256[] memory collateralAmounts
        ) = lending.getUserLoansWithStatus(obofte, Lending.LoanStatus.ACTIVE);

        assertEq(borrowTokens.length, 1, "Should have one active loan");
        assertEq(amounts[0], 700e18, "Active loan amount should be 700 DAI");
        assertEq(collateralAmounts[0], 0.7 ether, "Active loan collateral should be 0.7 WETH");

        // Get repaid loans
        (borrowTokens, collateralTokens, amounts, collateralAmounts) =
            lending.getUserLoansWithStatus(obofte, Lending.LoanStatus.REPAID);

        assertEq(borrowTokens.length, 1, "Should have one repaid loan");
        assertEq(amounts[0], 500e18, "Repaid loan amount should be 500 DAI");
        assertEq(collateralAmounts[0], 0.5 ether, "Repaid loan collateral should be 0.5 WETH");

        vm.stopPrank();
    }

    function testSequentialLoans() public funded(obofte) {
        vm.startPrank(obofte);

        // Setup approvals
        IERC20(weth).approve(address(lending), type(uint256).max);
        IERC20(dai).approve(address(lending), type(uint256).max);

        // First loan cycle: borrow and repay
        lending.depositCollateral(weth, 0.5 ether);
        lending.borrow(dai, weth, 500e18, 0.5 ether);

        // Get first loan state
        (uint256 amount1,, uint256 interest1, Lending.LoanStatus status1) = lending.getLoanDetails(obofte, dai, weth);
        assertEq(uint8(status1), uint8(Lending.LoanStatus.ACTIVE), "First loan should be active");

        // Repay first loan
        lending.repay(dai, weth, amount1 + interest1);

        // Verify first loan is now repaid
        (,,, Lending.LoanStatus status1After) = lending.getLoanDetails(obofte, dai, weth);
        assertEq(uint8(status1After), uint8(Lending.LoanStatus.REPAID), "First loan should be repaid");

        // Create second loan with same tokens
        lending.depositCollateral(weth, 0.7 ether);
        lending.borrow(dai, weth, 700e18, 0.7 ether);

        // Verify second loan state
        (uint256 amount2, uint256 collateral2,, Lending.LoanStatus status2) = lending.getLoanDetails(obofte, dai, weth);
        assertEq(amount2, 700e18, "Second loan amount should be 700 DAI");
        assertEq(collateral2, 0.7 ether, "Second loan collateral should be 0.7 WETH");
        assertEq(uint8(status2), uint8(Lending.LoanStatus.ACTIVE), "Second loan should be active");

        vm.stopPrank();
    }

    function testRevertsWhenCreatingDuplicateActiveLoan() public funded(obofte) {
        uint256 initialDeposit = 1 ether; // Initial 1 WETH deposit
        uint256 borrowAmount = 500e18;    // Borrow 500 DAI

        vm.startPrank(obofte);
        
        // First loan setup
        IERC20(weth).approve(address(lending), initialDeposit);
        lending.depositCollateral(weth, initialDeposit);
        lending.borrow(dai, weth, borrowAmount, initialDeposit);

        // Try to create second loan with same token pair
        vm.expectRevert(Lending.Lending__ActiveLoanExists.selector);
        lending.borrow(dai, weth, borrowAmount, initialDeposit);

        vm.stopPrank();

        // Verify only one loan exists
        (uint256 loanAmount,,, Lending.LoanStatus status) = lending.getLoanDetails(obofte, dai, weth);
        assertEq(loanAmount, borrowAmount, "Only one loan should exist");
        assertEq(uint8(status), uint8(Lending.LoanStatus.ACTIVE), "Loan should be active");
    }

    ////////////////////////////////
    //   increaseBorrow Tests    //
    ////////////////////////////////

    event LoanAmountIncreased(
        address indexed account,
        address indexed borrowToken,
        address indexed collateralToken,
        uint256 additionalAmount,
        uint256 newTotalAmount
    );

    modifier withExistingLoan(address user) {
        // Get some tokens for user
        vm.startPrank(user);
        faucetContract.requestTokens();

        // Deposit collateral
        ERC20(weth).approve(address(lending), DEPOSIT_AMOUNT);
        lending.depositCollateral(weth, DEPOSIT_AMOUNT);

        // Create initial loan
        lending.borrow(dai, weth, BORROW_AMOUNT, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testIncreaseBorrowSuccess() public withExistingLoan(debtor) {
        uint256 additionalAmount = 0.1 ether;
        uint256 expectedNewTotal = BORROW_AMOUNT + additionalAmount;

        vm.startPrank(debtor);
        vm.expectEmit(true, true, true, true, address(lending));
        emit LoanAmountIncreased(debtor, dai, weth, additionalAmount, expectedNewTotal);
        
        lending.increaseBorrow(dai, weth, additionalAmount);
        
        // Verify loan was updated
        (uint256 loanAmount,,, Lending.LoanStatus status) = lending.getLoanDetails(debtor, dai, weth);
        assertEq(loanAmount, expectedNewTotal, "Loan amount should increase");
        assertEq(uint256(status), uint256(Lending.LoanStatus.ACTIVE), "Loan should remain active");
        vm.stopPrank();
    }

    function testRevertsWhenIncreasingNonExistentLoan() public {
        vm.startPrank(debtor);
        vm.expectRevert(Lending.Lending__NoLoanFound.selector);
        lending.increaseBorrow(dai, weth, 1 ether);
        vm.stopPrank();
    }

    function testRevertsWhenProtocolHasInsufficientLiquidity() public withExistingLoan(debtor) {
        // Simulate protocol having no liquidity by transferring all DAI out
        uint256 protocolBalance = ERC20(dai).balanceOf(address(lending));
        vm.prank(address(lending));
        ERC20(dai).transfer(address(1), protocolBalance);
        
        vm.startPrank(debtor);
        vm.expectRevert(Lending.Lending__NotEnoughTokenInVaultToBorrow.selector);
        lending.increaseBorrow(dai, weth, 1 ether);
        vm.stopPrank();
    }

    function testIncreaseBorrowUpdatesLoanHistory() public withExistingLoan(debtor) {
        uint256 additionalAmount = 100e18; // Additional 100 DAI
        
        vm.startPrank(debtor);
        lending.increaseBorrow(dai, weth, additionalAmount);
        
        // Get loan history
        (
            bytes32[] memory loanIds,
            address[] memory borrowTokens,
            address[] memory collateralTokens,
            uint256[] memory amounts,
            ,
            Lending.LoanStatus[] memory statuses
        ) = lending.getUserLoanHistory(debtor);
        
        assertEq(borrowTokens[0], dai, "Borrow token should be DAI");
        assertEq(collateralTokens[0], weth, "Collateral token should be WETH");
        assertEq(amounts[0], BORROW_AMOUNT + additionalAmount, "Amount should include increase");
        assertEq(uint256(statuses[0]), uint256(Lending.LoanStatus.ACTIVE), "Loan should be active");
        vm.stopPrank();
    }
}
