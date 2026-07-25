# Flex Allocator

Yearn V3 strategies for lending into [Flex](https://github.com/flexmeow/flex-contracts) markets.

## Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/flexmeow/flex-allocator.git
   cd flex-allocator
   ```

2. **Environment setup**
   ```bash
   cp .env.example .env
   ```

## Usage

```bash
# Build flex-contracts (needed once for the market-deployment test artifacts, requires vyper 0.4.3)
forge build --root lib/flex-contracts

# Build
forge build

# Test
forge test

# Format
forge fmt .
```