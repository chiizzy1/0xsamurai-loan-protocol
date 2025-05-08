//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {WETH} from "../src/faucet/WETH.sol";
import {WBTC} from "../src/faucet/WBTC.sol";
import {DAI} from "../src/faucet/DAI.sol";
import {FaucetTokens} from "../src/faucet/FaucetTokens.sol";

contract DeployFaucet is Script {
    function run() external returns (WETH, WBTC, DAI, FaucetTokens) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        WETH weth = new WETH();
        WBTC wbtc = new WBTC();
        DAI dai = new DAI();
        FaucetTokens faucet = new FaucetTokens(address(weth), address(wbtc), address(dai));

        weth.transferOwnership(address(faucet));
        wbtc.transferOwnership(address(faucet));
        dai.transferOwnership(address(faucet));
        vm.stopBroadcast();

        return (weth, wbtc, dai, faucet);
    }
}

// source .env
// forge script script/DeployFaucet.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify -vvvv

// == Return ==
// 0: contract WETH 0x19c1507940AE9e42203e5FA368078Cb7E18ED9db
// 1: contract WBTC 0x87196979027b5CBc15c2A599F280fA84A0a60938
// 2: contract DAI 0x33947860a94AC4938554F0B972Ea53588d7e3884
// 3: contract FaucetTokens 0x5876c82aA09e46B37450e1527210e3d36AeCc8bE
