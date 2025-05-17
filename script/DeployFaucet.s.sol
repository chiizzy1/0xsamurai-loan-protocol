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
