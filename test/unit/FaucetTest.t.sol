//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {FaucetTokens} from "../../src/faucet/FaucetTokens.sol";
import {WETH} from "../../src/faucet/WETH.sol";
import {WBTC} from "../../src/faucet/WBTC.sol";
import {DAI} from "../../src/faucet/DAI.sol";
import {DeployLending} from "../../script/DeployLending.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Lending} from "../../src/Lending.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FaucetTest is Test {
    HelperConfig public helperConfig;
    Lending public lending;

    address public weth;
    address public wbtc;
    address public dai;
    address public wethUsdPriceFeed;
    address public wbtcUsdPriceFeed;
    address public daiUsdPriceFeed;
    address public faucet;

    address public obofte = makeAddr("obofte");
    address public yamal = makeAddr("yamal");
    address public sakadinho = makeAddr("sakadinho");

    function setUp() public {
        DeployLending deployer = new DeployLending();
        (lending, helperConfig) = deployer.run();

        (weth, wbtc, dai, wethUsdPriceFeed, wbtcUsdPriceFeed, daiUsdPriceFeed, faucet,) =
            helperConfig.activeNetworkConfig();
    }

    function testFaucet() public {
        // Convert faucet address to FaucetTokens type for easier interaction
        FaucetTokens faucetContract = FaucetTokens(faucet);

        // Get initial balances
        uint256 initialWethBalance = IERC20(weth).balanceOf(obofte);
        uint256 initialWbtcBalance = IERC20(wbtc).balanceOf(obofte);
        uint256 initialDaiBalance = IERC20(dai).balanceOf(obofte);
        console.log("Initial WETH balance:", initialWethBalance);
        console.log("Initial WBTC balance:", initialWbtcBalance);
        console.log("Initial DAI balance:", initialDaiBalance);

        // Request tokens as obofte
        vm.startPrank(obofte);
        // Warp time forward to ensure we're past any cooldown
        // vm.warp(block.timestamp + 1 days);
        faucetContract.requestTokens();
        vm.stopPrank();

        // Get final balances
        uint256 finalWethBalance = IERC20(weth).balanceOf(obofte);
        uint256 finalWbtcBalance = IERC20(wbtc).balanceOf(obofte);
        uint256 finalDaiBalance = IERC20(dai).balanceOf(obofte);
        console.log("Final WETH balance:", finalWethBalance);
        console.log("Final WBTC balance:", finalWbtcBalance);
        console.log("Final DAI balance:", finalDaiBalance);

        // Assert correct amounts were minted
        assertEq(finalWethBalance - initialWethBalance, 2 ether, "Should receive 2 WETH");
        assertEq(finalWbtcBalance - initialWbtcBalance, 1 ether, "Should receive 1 WBTC");
        assertEq(finalDaiBalance - initialDaiBalance, 10_000 ether, "Should receive 10,000 DAI");
    }

    function testCooldownPeriod() public {
        FaucetTokens faucetContract = FaucetTokens(faucet);

        // First request should work
        vm.startPrank(obofte);
        faucetContract.requestTokens();

        // Try to request again immediately - expect custom error
        vm.expectRevert(
            abi.encodeWithSelector(
                FaucetTokens.FaucetTokens__24HoursCooldownPeriodIsRequired.selector,
                block.timestamp // This is the lastRequestTime that will be in the error
            )
        );
        faucetContract.requestTokens();
        vm.stopPrank();

        // Warp time forward past cooldown
        vm.warp(block.timestamp + 1 days);

        // Should work again after cooldown
        vm.prank(obofte);
        faucetContract.requestTokens();
    }

    function testMultipleUsersClaimFaucet() public {
        FaucetTokens faucetContract = FaucetTokens(faucet);

        // Alice can request
        vm.prank(yamal);
        faucetContract.requestTokens();

        // Bob can also request
        vm.prank(sakadinho);
        faucetContract.requestTokens();

        // Both should have received tokens
        assertEq(IERC20(weth).balanceOf(yamal), 2 ether, "Yamal should have 2 WETH");
        assertEq(IERC20(weth).balanceOf(sakadinho), 2 ether, "Sakadinho should have 2 WETH");
    }

    function testRequestTokensEmitsCorrectEvent() public {
        FaucetTokens faucetContract = FaucetTokens(faucet);

        vm.startPrank(obofte);
        // Expect an event with specific parameters
        vm.expectEmit(true, true, true, true);
        // Define the expected event
        emit FaucetTokens.TokensDistributed(
            obofte,
            2 ether, // wethAmount
            1 ether, // wbtcAmount
            10_000 ether // daiAmount
        );
        faucetContract.requestTokens();
        vm.stopPrank();
    }

    function testOnlyOwnerCanSetDistributionAmounts() public {
        FaucetTokens faucetContract = FaucetTokens(faucet);

        // Non-owner should fail
        vm.startPrank(obofte);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                obofte // unauthorized account
            )
        );
        faucetContract.setDistributionAmounts(1 ether, 0.5 ether, 5_000 ether);
        vm.stopPrank();

        // Owner should succeed
        uint256 newWethAmount = 1 ether;
        uint256 newWbtcAmount = 0.5 ether;
        uint256 newDaiAmount = 5_000 ether;

        console.log("contract owner: ", faucetContract.owner());
        console.log("obofte: ", obofte);

        vm.prank(faucetContract.owner());
        faucetContract.setDistributionAmounts(newWethAmount, newWbtcAmount, newDaiAmount);

        assertEq(faucetContract.wethAmount(), newWethAmount);
        assertEq(faucetContract.wbtcAmount(), newWbtcAmount);
        assertEq(faucetContract.daiAmount(), newDaiAmount);
    }

    function testOnlyOwnerCanSetCooldown() public {
        FaucetTokens faucetContract = FaucetTokens(faucet);
        uint256 newCooldown = 12 hours;

        // Non-owner should fail
        vm.prank(obofte);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                obofte // unauthorized account
            )
        );
        faucetContract.setCooldown(newCooldown);
        // Owner should succeed
        vm.prank(faucetContract.owner());
        faucetContract.setCooldown(newCooldown);
        assertEq(faucetContract.requestCooldown(), newCooldown);
    }

    function testSetTokenAddressesRevertOnZeroAddress() public {
        FaucetTokens faucetContract = FaucetTokens(faucet);
        vm.startPrank(faucetContract.owner());

        vm.expectRevert(FaucetTokens.FaucetTokens__AddressZeroIsNotAllowed.selector);
        faucetContract.setTokenAddresses(address(0), address(wbtc), address(dai));

        vm.expectRevert(FaucetTokens.FaucetTokens__AddressZeroIsNotAllowed.selector);
        faucetContract.setTokenAddresses(address(weth), address(0), address(dai));

        vm.expectRevert(FaucetTokens.FaucetTokens__AddressZeroIsNotAllowed.selector);
        faucetContract.setTokenAddresses(address(weth), address(wbtc), address(0));

        vm.stopPrank();
    }

    function testRequestTokensUpdatesLastRequestTime() public {
        FaucetTokens faucetContract = FaucetTokens(faucet);

        vm.prank(obofte);
        faucetContract.requestTokens();

        assertEq(faucetContract.lastRequestTime(obofte), block.timestamp, "Last request time should be updated");
    }

    function testConstructorRevertOnZeroAddress() public {
        vm.expectRevert(FaucetTokens.FaucetTokens__AddressZeroIsNotAllowed.selector);
        new FaucetTokens(address(0), address(wbtc), address(dai));

        vm.expectRevert(FaucetTokens.FaucetTokens__AddressZeroIsNotAllowed.selector);
        new FaucetTokens(address(weth), address(0), address(dai));

        vm.expectRevert(FaucetTokens.FaucetTokens__AddressZeroIsNotAllowed.selector);
        new FaucetTokens(address(weth), address(wbtc), address(0));
    }
}

// forge test --mp test/unit/FaucetTest.t.sol
// forge test --mp test/unit/LendingTest.t.sol
// forge test --match-test testFaucet -vvvv
// forge test --match-test testFaucet --rpc-url $SEPOLIA_RPC_URL -vvvv
