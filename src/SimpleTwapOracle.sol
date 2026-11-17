// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {SimplePool} from "./SimplePool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SimpleTwapOracle {
    uint256 public constant PERIOD = 30 minutes;

    SimplePool public immutable pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public timestampLast;
    uint256 public price0Average;
    uint256 public price1Average;

    event OracleUpdated(uint256 price0Average, uint256 price1Average, uint256 elapsed);

    error Oracle__NoLiquidity();
    error Oracle__PeriodNotElapsed(uint256 elapsed, uint256 period);
    error Oracle__NotReady();
    error Oracle__InvalidToken(IERC20 token);

    constructor(SimplePool _pool) {
        if (_pool.reserve0() == 0 || _pool.reserve1() == 0) revert Oracle__NoLiquidity();
        pool = _pool;
        token0 = pool.token0();
        token1 = pool.token1();
        (price0CumulativeLast, price1CumulativeLast, timestampLast) = pool.currentCumulativePrices();
    }

    function update() public {
        (uint256 c0, uint256 c1, uint256 t) = pool.currentCumulativePrices();
        uint256 elapsed = t - timestampLast;
        if (elapsed < PERIOD) revert Oracle__PeriodNotElapsed(elapsed, PERIOD);
        unchecked {
            price0Average = (c0 - price0CumulativeLast) / elapsed;
            price1Average = (c1 - price1CumulativeLast) / elapsed;
        }
        price0CumulativeLast = c0;
        price1CumulativeLast = c1;
        timestampLast = t;
        emit OracleUpdated(price0Average, price1Average, elapsed);
    }

    function consult(IERC20 token, uint256 amountIn) external view returns (uint256) {
        if (price0Average == 0 || price1Average == 0) revert Oracle__NotReady();
        if (address(token) != address(token0) && address(token) != address(token1)) revert Oracle__InvalidToken(token);
        if (address(token) == address(token0)) {
            return amountIn * price0Average >> 112;
        }
        return amountIn * price1Average >> 112;
    }
}
