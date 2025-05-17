//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.t.sol";
import {FaucetTokens} from "../src/faucet/FaucetTokens.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WETH} from "../src/faucet/WETH.sol";
import {WBTC} from "../src/faucet/WBTC.sol";
import {DAI} from "../src/faucet/DAI.sol";

contract HelperConfig is Script {
    NetworkConfig public activeNetworkConfig;

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8; //$2000/ETH
    int256 public constant BTC_USD_PRICE = 100000e8; //$100,000/BTC
    int256 public constant DAI_USD_PRICE = 1e8; //$1/DAI --> stablecoin

    uint256 public DEFAULT_ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    struct NetworkConfig {
        address weth;
        address wbtc;
        address dai;
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address daiUsdPriceFeed;
        address faucet;
        uint256 deployerKey;
    }

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory sepoliaNetworkConfig) {
        sepoliaNetworkConfig = NetworkConfig({
            weth: 0xa550bc219F151353e92979eAC717E958800eaABf, // Deployed WETH
            wbtc: 0xE17002758791c5C2A8A2654f5E719607F4A7Fc18, // Deployed WBTC
            dai: 0xACe6a5728D161B01437594aB0a501187e521AEE6, // Deployed DAI
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306, // Sepolia ETH/USD
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43, // Sepolia BTC/USD
            daiUsdPriceFeed: 0x14866185B1962B63C3Ea9E03Bc1da838bab34C19, // Sepolia DAI/USD
            faucet: 0x1afe87187A4f032BfA745D02a4639eDE6d4a1e71, // Deployed Faucet
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory anvilNetworkConfig) {
        // Check to see if we set an active network config
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        // Deploy mock price feeds
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);
        MockV3Aggregator daiUsdPriceFeed = new MockV3Aggregator(DECIMALS, DAI_USD_PRICE);

        // Deploy mock tokens with correct names and symbols
        WETH mockWeth = new WETH();
        WBTC mockWbtc = new WBTC();
        DAI mockDai = new DAI();

        // Deploy mock faucet
        FaucetTokens faucet = new FaucetTokens(address(mockWeth), address(mockWbtc), address(mockDai));

        // Transfer ownership of tokens to faucet
        mockWeth.transferOwnership(address(faucet));
        mockWbtc.transferOwnership(address(faucet));
        mockDai.transferOwnership(address(faucet));

        vm.stopBroadcast();

        anvilNetworkConfig = NetworkConfig({
            weth: address(mockWeth),
            wbtc: address(mockWbtc),
            dai: address(mockDai),
            wethUsdPriceFeed: address(ethUsdPriceFeed),
            wbtcUsdPriceFeed: address(btcUsdPriceFeed),
            daiUsdPriceFeed: address(daiUsdPriceFeed),
            faucet: address(faucet),
            deployerKey: DEFAULT_ANVIL_PRIVATE_KEY
        });
    }
}
