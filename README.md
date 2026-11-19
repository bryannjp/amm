# SimplePool

A constant-product AMM (x · y = k) written from scratch in Solidity, tested against the real Uniswap V2 pair.

## What it does
Two-token pool: add liquidity for LP shares, swap with a 0.3% fee that stays with LPs, remove liquidity for your share of both tokens.

v2 adds:
- Price accumulators (Uniswap V2 style): running totals of price × seconds, updated before every action
- `SimpleTwapOracle`: reads the pool and gives the 30-minute time-weighted average price (TWAP)
- Reserves capped at 2^112 so the accumulators can never overflow

v3 adds:
- ERC-3156 flash loans: borrow either token with no collateral, repaid with a 0.3% fee in the same transaction
- The fee goes to the reserves, so LPs earn it like swap fees

## Design decisions
- First deposit gets √(x·y) − 1,000 shares; the 1,000 are locked forever (inflation-attack defence)
- Later deposits only take the amounts matching the current ratio
- Slippage protection on every action (`minShares`, `minAmount0/1`, `minAmountOut`) plus a swap deadline
- Reserves updated before any token moves (no stale reads during transfers); `nonReentrant` on all actions
- Pull model (`transferFrom`) instead of Uniswap's push model, so no router is needed
- Not supported: fee-on-transfer tokens; tokens sent directly to the pool are not counted (no skim/sync)
- Spot prices can be moved inside one transaction; the TWAP ignores same-transaction manipulation and makes longer manipulation expensive
- Limitations: the TWAP lags real price moves, and someone (a keeper bot) must call `update()` every 30 minutes
- The borrower's callback must return the ERC-3156 magic value, so nobody can be made to pay fees for a loan they did not start
- The borrower receives the real initiator (`msg.sender`), so standard borrowers can reject loans they did not start
- All actions are blocked during a loan (`nonReentrant`); reserves stay unchanged until the loan is repaid

## Testing
- 96 unit tests, incl. a full flash-loan liquidation, victims who approved the pool, and oracle edge cases
- Differential fuzz tests against the real Uniswap V2 pair: identical shares, payouts, reserves and price accumulators
- 8 invariants, incl. "a flash loan changes the reserves by exactly its fee"
- Mutation testing: 112/112 mutants killed
- 100% line and branch coverage

## Run it
    forge install
    forge build
    forge test

Uniswap V2 (GPL-3.0) is used only as a test reference in `lib/`.

## AI usage
Code written by me; Claude used as a reviewer and to write tests. Every claim verified by compiling and running.
