// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract SimplePool is ERC20, ReentrancyGuard {
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;
    address public constant DEAD = address(0xdead);

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint256 public reserve0;
    uint256 public reserve1;

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 mintedShares);
    event LiquidityRemoved(address indexed taker, uint256 amount0, uint256 amount1, uint256 burnedShares);
    event Swap(address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    error Pool__ZeroAddress();
    error Pool__IdenticalTokens();
    error Pool__ZeroAmount();
    error Pool__InsufficientInitialLiquidity();
    error Pool__SlippageExceeded(uint256 actual, uint256 minimal);
    error Pool__Expired(uint256 timeDeadline);
    error Pool__InvalidToken(address token);

    constructor(IERC20 token0_, IERC20 token1_, string memory name, string memory symbol) ERC20(name, symbol) {
        if (address(token0_) == address(0) || address(token1_) == address(0)) revert Pool__ZeroAddress();
        if (address(token0_) == address(token1_)) revert Pool__IdenticalTokens();

        token0 = token0_;
        token1 = token1_;
    }

    function addLiquidity(uint256 amount0Desired, uint256 amount1Desired, uint256 minShares)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        if (amount0Desired == 0 || amount1Desired == 0) revert Pool__ZeroAmount();
        if (totalSupply() == 0) {
            // first time
            amount0 = amount0Desired;
            amount1 = amount1Desired;
            uint256 root = Math.sqrt(amount0Desired * amount1Desired);
            if (root <= MINIMUM_LIQUIDITY) revert Pool__InsufficientInitialLiquidity();
            shares = root - MINIMUM_LIQUIDITY;
            _mint(DEAD, MINIMUM_LIQUIDITY);
        } else {
            uint256 amount1Optimal = amount0Desired * reserve1 / reserve0;
            if (amount1Optimal <= amount1Desired) {
                amount0 = amount0Desired;
                amount1 = amount1Optimal;
            } else {
                amount0 = amount1Desired * reserve0 / reserve1;
                amount1 = amount1Desired;
            }
            shares = Math.min(amount0 * totalSupply() / reserve0, amount1 * totalSupply() / reserve1);
        }
        if (shares == 0) revert Pool__ZeroAmount();
        if (shares < minShares) revert Pool__SlippageExceeded(shares, minShares);
        reserve0 += amount0;
        reserve1 += amount1;
        SafeERC20.safeTransferFrom(token0, msg.sender, address(this), amount0);
        SafeERC20.safeTransferFrom(token1, msg.sender, address(this), amount1);
        _mint(msg.sender, shares);
        emit LiquidityAdded(msg.sender, amount0, amount1, shares);
    }

    function removeLiquidity(uint256 shares, uint256 minAmount0, uint256 minAmount1)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = shares * reserve0 / totalSupply();
        amount1 = shares * reserve1 / totalSupply();
        if (amount0 == 0 || amount1 == 0) revert Pool__ZeroAmount();
        if (amount0 < minAmount0) revert Pool__SlippageExceeded(amount0, minAmount0);
        if (amount1 < minAmount1) revert Pool__SlippageExceeded(amount1, minAmount1);
        _burn(msg.sender, shares);
        reserve0 -= amount0;
        reserve1 -= amount1;
        SafeERC20.safeTransfer(token0, msg.sender, amount0);
        SafeERC20.safeTransfer(token1, msg.sender, amount1);
        emit LiquidityRemoved(msg.sender, amount0, amount1, shares);
    }

    function swap(address _tokenIn, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Pool__Expired(deadline); // stops a transaction stuck in the mempool from executing hours later at a bad price.
        if (_tokenIn != address(token0) && _tokenIn != address(token1)) revert Pool__InvalidToken(_tokenIn);

        bool zero = _tokenIn == address(token0);
        IERC20 tokenIn = zero ? token0 : token1;
        IERC20 tokenOut = zero ? token1 : token0;
        uint256 reserveIn = zero ? reserve0 : reserve1;
        uint256 reserveOut = zero ? reserve1 : reserve0;
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        if (amountOut == 0) revert Pool__ZeroAmount();
        if (amountOut < minAmountOut) revert Pool__SlippageExceeded(amountOut, minAmountOut);
        if (zero) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve0 -= amountOut;
            reserve1 += amountIn;
        }
        SafeERC20.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        SafeERC20.safeTransfer(tokenOut, msg.sender, amountOut);
        emit Swap(msg.sender, _tokenIn, amountIn, amountOut);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        uint256 amountInMinusFee = amountIn * 997;
        return amountInMinusFee * reserveOut / (amountInMinusFee + reserveIn * 1000);
    }
}
