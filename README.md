# C-lend — Collateralized Lending Market

A self-contained Foundry implementation of a collateralized ERC-20 lending market with a mock USD oracle.

## Assignment coverage

- ERC-20 collateral deposits and ERC-20 borrowing.
- Owner-configured supported assets, collateral factors, liquidation thresholds, liquidation bonuses, APRs, and oracle freshness windows.
- Borrow limits based on normalized 1e18 USD oracle values, including support for different token decimals.
- Per-user principal and time-based simple interest accounting.
- Partial repayment, full repayment with `type(uint256).max`, and third-party repayment.
- Collateral withdrawals only while the account remains above the liquidation threshold.
- Oracle validation that rejects missing prices, stale prices, future timestamps, and unsupported assets.
- Bounded liquidation using a 50% close factor, available-collateral cap, and configurable liquidation bonus.
- Explicit bad-debt detection when collateral is exhausted while debt remains.
- Required deposit, borrow, repay, liquidation, and withdrawal events.

## Contracts

### `src/CollateralizedLending.sol`

The lending market. Prices are expected in 18-decimal USD precision. Token decimals are read when an asset is configured and used for value normalization.

Risk parameters are separated intentionally:

- `collateralFactorBps` controls how much new debt a position may open.
- `liquidationThresholdBps` controls when the account becomes liquidatable.
- `liquidationBonusBps` determines the extra collateral received by a liquidator.
- `interestRateBps` is a simple annual interest rate accrued by elapsed timestamp.
- `maxPriceAge` defines the maximum accepted oracle age.

The market uses a 50% close factor per liquidation. If available collateral cannot support that much repayment plus the bonus, the repayment is reduced so a liquidator cannot be overcharged.

### `src/MockOracle.sol`

A mock price oracle with normal updates, arbitrary timestamps for stale-price tests, and price clearing for missing-price tests.

### `src/MockERC20.sol`

A minimal mintable ERC-20 used by the test suite. The tests use 18-decimal WETH collateral and 6-decimal USDC debt to exercise decimal normalization.

## Foundry proof

`test/CollateralizedLending.t.sol` is dependency-free and directly uses Foundry's cheatcode address, so `forge-std` is not required.

The suite proves:

- healthy borrowing;
- interest accrual with `vm.warp`;
- price-drop health deterioration;
- over-borrow prevention;
- partial and full repayment;
- healthy-only collateral withdrawals;
- liquidation bonus calculations;
- 50% close-factor enforcement;
- rejection of liquidation against healthy accounts;
- stale prices;
- missing prices;
- unsupported assets; and
- bad debt after a severe collateral price crash.

## Run

```bash
forge test -vv
```

For gas reporting:

```bash
forge test --gas-report
```

## Notes

Borrowed-asset liquidity is pre-funded in the tests by minting the borrow asset to the market contract. LP shares, variable-rate models, protocol reserves, governance, and production oracle integrations are intentionally outside this assignment's scope.
