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

- WETH: `0xa550bc219F151353e92979eAC717E958800eaABf`
- WBTC: `0xE17002758791c5C2A8A2654f5E719607F4A7Fc18`
- DAI: `0xACe6a5728D161B01437594aB0a501187e521AEE6`
- Faucet: `0x1afe87187A4f032BfA745D02a4639eDE6d4a1e71`
- Lending Protocol: `0xa4C7Cd95Cb7da9e582c3f85b577034f7A17d6E14`

## Development

### Prerequisites

- Foundry
- Make
- Git

### Setup

```bash
git clone https://github.com/chiizzy1/0xsamurai-loan-protocol.git
cd 0xsamurai-loan-protocol
forge install
```

### Environment Variables

Create a `.env` file in the root directory and add the following variables:

```env
# Deployment
PRIVATE_KEY=your_wallet_private_key
SEPOLIA_RPC_URL=your_sepolia_rpc_url
ETHERSCAN_API_KEY=your_etherscan_api_key

# Local Development
RPC_URL=http://127.0.0.1:8545  # Default Anvil URL
```

You can copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
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
