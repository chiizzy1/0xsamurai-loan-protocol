//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {Lending} from "../src/Lending.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {FaucetTokens} from "../src/faucet/FaucetTokens.sol";

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
            address faucet,
            uint256 deployerKey
        ) = helperConfig.activeNetworkConfig();

        tokenAddresses = [weth, wbtc, dai];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed, daiUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        Lending lending = new Lending(tokenAddresses, priceFeedAddresses);

        // Request tokens to be minted directly to the lending contract
        FaucetTokens(faucet).requestTokensFor(address(lending));
        vm.stopBroadcast();
        return (lending, helperConfig);
    }
}
