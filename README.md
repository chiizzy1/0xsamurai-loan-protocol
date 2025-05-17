# SamuraiLoan Protocol

A decentralized lending and borrowing protocol that enables users to deposit collateral and borrow tokens with specific token-to-token pairs.

## Overview

SamuraiLoan is a lending protocol that allows users to:
- Deposit supported tokens as collateral
- Borrow other supported tokens against their collateral
- Repay loans with accrued interest
- Liquidate unhealthy positions
- Manage collateral ratios to avoid liquidation

## Key Features

- **Token-Specific Collateralization**: Each loan is backed by specific collateral tokens
- **Dynamic Interest Rate**: 3% APR on all borrowed amounts
- **Liquidation System**: Positions become liquidatable at 80% Loan-to-Value ratio
- **Oracle Integration**: Uses Chainlink price feeds for secure price data
- **Price Staleness Check**: 3-hour timeout for price feed data
- **Liquidation Incentives**: 10% bonus for liquidators

## Supported Tokens
- WETH (Wrapped Ether)
- WBTC (Wrapped Bitcoin)
- DAI (Stablecoin)

## Technical Details

- **Health Factor**: Minimum 1.0 (with 18 decimals precision)
- **Liquidation Threshold**: 80%
- **Interest Calculation**: Per-second interest accrual
- **Collateralization**: Over-collateralized loans only

## Deployed Contracts (Sepolia)

- WETH: `0x19c1507940AE9e42203e5FA368078Cb7E18ED9db`
- WBTC: `0x87196979027b5CBc15c2A599F280fA84A0a60938`
- DAI: `0x33947860a94AC4938554F0B972Ea53588d7e3884`
- Faucet: `0x5876c82aA09e46B37450e1527210e3d36AeCc8bE`
- Lending Protocol: `0x32dc459685Cf36F9a2AF307D2dADb616DE5F71a9`

## Development

### Prerequisites
- Foundry
- Make
- Git

### Setup
```bash
git clone <repository-url>
cd samuraiLoan-protocol
forge install
```

### Build
```bash
forge build
```

### Test
```bash
forge test
```

### Deploy
```bash
# Deploy to Sepolia
make deploy-all

# Deploy to local Anvil chain
make deploy-anvil
```

### Get Test Tokens (Sepolia)
The protocol includes a faucet contract that provides test tokens (WETH, WBTC, DAI) for testing purposes. Users can request tokens once every 24 hours.

## Security Considerations

- Uses OpenZeppelin's ReentrancyGuard
- Implements checks-effects-interactions pattern
- Price feed staleness checks
- No flash loan vulnerabilities
- Proper decimal handling for token calculations

## License

MIT License

## Author

0xSamurai
