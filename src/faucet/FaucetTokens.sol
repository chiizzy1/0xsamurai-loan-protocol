//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {WETH} from "./WETH.sol";
import {WBTC} from "./WBTC.sol";
import {DAI} from "./DAI.sol";

contract FaucetTokens is Ownable {
    error FaucetTokens__24HoursCooldownPeriodIsRequired(uint256 lastRequestTime);
    error FaucetTokens__AddressZeroIsNotAllowed();

    WETH public weth;
    WBTC public wbtc;
    DAI public dai;

    // Track last request time to prevent abuse
    mapping(address => uint256) public lastRequestTime;
    uint256 public requestCooldown = 24 hours;

    // Token amounts to distribute to regular users
    uint256 public wethAmount = 100000 * 10 ** 18; // 100,000 ETH
    uint256 public wbtcAmount = 10000 * 10 ** 18; // 10,000 BTC
    uint256 public daiAmount = 100000000 * 10 ** 18; // 100,000,000 DAI

    event TokensDistributed(address recipient, uint256 wethAmount, uint256 wbtcAmount, uint256 daiAmount);
    event CooldownUpdated(uint256 newCooldown);
    event TokenAddressesUpdated(address weth, address wbtc, address dai);
    event DistributionAmountsUpdated(uint256 wethAmount, uint256 wbtcAmount, uint256 daiAmount);

    constructor(address _weth, address _wbtc, address _dai) Ownable(msg.sender) {
        if (_weth == address(0) || _wbtc == address(0) || _dai == address(0)) {
            revert FaucetTokens__AddressZeroIsNotAllowed();
        }

        weth = WETH(_weth);
        wbtc = WBTC(_wbtc);
        dai = DAI(_dai);
    }

    /**
     * @dev Request tokens from the faucet
     */
    function requestTokens() external {
        // Check if this is first request or cooldown has passed
        if (lastRequestTime[msg.sender] != 0) {
            if (block.timestamp < lastRequestTime[msg.sender] + requestCooldown) {
                revert FaucetTokens__24HoursCooldownPeriodIsRequired(lastRequestTime[msg.sender]);
            }
        }

        // Update last request time
        lastRequestTime[msg.sender] = block.timestamp;

        // Mint tokens to the requester
        weth.mint(msg.sender, wethAmount);
        wbtc.mint(msg.sender, wbtcAmount);
        dai.mint(msg.sender, daiAmount);

        emit TokensDistributed(msg.sender, wethAmount, wbtcAmount, daiAmount);
    }

    /**
     * @dev Allow the owner to update token distribution amounts
     */
    function setDistributionAmounts(uint256 _wethAmount, uint256 _wbtcAmount, uint256 _daiAmount) external onlyOwner {
        wethAmount = _wethAmount;
        wbtcAmount = _wbtcAmount;
        daiAmount = _daiAmount;
        emit DistributionAmountsUpdated(_wethAmount, _wbtcAmount, _daiAmount);
    }

    /**
     * @dev Update the cooldown period
     */
    function setCooldown(uint256 _requestCooldown) external onlyOwner {
        requestCooldown = _requestCooldown;
        emit CooldownUpdated(_requestCooldown);
    }

    /**
     * @dev Allow the owner to update token contract addresses if needed
     */
    function setTokenAddresses(address _weth, address _wbtc, address _dai) external onlyOwner {
        if (_weth == address(0) || _wbtc == address(0) || _dai == address(0)) {
            revert FaucetTokens__AddressZeroIsNotAllowed();
        }
        weth = WETH(_weth);
        wbtc = WBTC(_wbtc);
        dai = DAI(_dai);
        emit TokenAddressesUpdated(_weth, _wbtc, _dai);
    }
}
