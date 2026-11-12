# SimplePool

A constant-product AMM (x · y = k) written from scratch in Solidity, tested against the real Uniswap V2 pair.

## What it does
Two-token pool: add liquidity for LP shares, swap with a 0.3% fee that stays with LPs, remove liquidity for your share of both tokens.

## Design decisions
- First deposit gets √(x·y) − 1,000 shares; the 1,000 are locked forever (inflation-attack defence)
- Later deposits only take the amounts matching the current ratio
- Slippage protection on every action (`minShares`, `minAmount0/1`, `minAmountOut`) plus a swap deadline
- Reserves updated before any token moves (no stale reads during transfers); `nonReentrant` on all actions
- Pull model (`transferFrom`) instead of Uniswap's push model, so no router is needed
- Not supported: fee-on-transfer tokens; tokens sent directly to the pool are not counted (no skim/sync)

## Testing
- 46 unit tests, incl. equal reserves, reentrancy and stale-reserve checks
- Differential fuzz tests against the real Uniswap V2 pair (identical shares, payouts and reserves; every payout passes Uniswap's K check, one unit more fails)
- 5 invariants (reserves vs balances, k never drops on swaps, fair removals, locked liquidity, supply)
- Mutation testing: 58/60 mutants killed (the 2 survivors are redundant checks)
- 100% line and branch coverage

## Run it
    forge install
    forge build
    forge test

Uniswap V2 (GPL-3.0) is used only as a test reference in `lib/`.

## AI usage
Code written by me; Claude used as a reviewer and to write tests. Every claim verified by compiling and running.
