//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {Lending} from "../src/Lending.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployLending is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (Lending, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        (
            address weth,
            address wbtc,
            address dai,
            address wethUsdPriceFeed,
            address wbtcUsdPriceFeed,
            address daiUsdPriceFeed,
            ,
            uint256 deployerKey
        ) = helperConfig.activeNetworkConfig();

        tokenAddresses = [weth, wbtc, dai];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed, daiUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        Lending lending = new Lending(tokenAddresses, priceFeedAddresses);
        vm.stopBroadcast();
        return (lending, helperConfig);
    }
}

// forge script script/DeployLending.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify -vvvv

// == Return ==
// 0: contract Lending 0x32dc459685Cf36F9a2AF307D2dADb616DE5F71a9
// 1: contract HelperConfig 0xC7f2Cf4845C6db0e1a1e91ED41Bcd0FcC1b0E141
