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

        // Fund the lending contract with initial liquidity
        vm.startPrank(address(lending));
        faucetContract.requestTokens();
        vm.stopPrank();
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
        vm.startPrank(user);
        faucetContract.requestTokens();
        vm.stopPrank();
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

        assertEq(wethBalance, WETH_FAUCET_AMOUNT, "Lending contract should receive 2 WETH from faucet");
        assertEq(wbtcBalance, WBTC_FAUCET_AMOUNT, "Lending contract should receive 1 WBTC from faucet");
        assertEq(daiBalance, DAI_FAUCET_AMOUNT, "Lending contract should receive 10_000 DAI from faucet");
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
}
