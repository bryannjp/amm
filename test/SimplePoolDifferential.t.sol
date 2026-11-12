// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SimplePool} from "../src/SimplePool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// The parts of the real Uniswap V2 pair (compiled with solc 0.5.16 from lib/v2-core) that the tests use.
interface IUniswapV2PairLike {
    function initialize(address, address) external;
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 timestamp);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
}

/// Runs the same operations on SimplePool and on the real Uniswap V2 pair and requires identical results.
/// Uniswap uses the "push" model (send tokens, then call), so each step is replayed that way on the pair.
contract SimplePoolDifferentialTest is Test {
    MockERC20 internal a0; // SimplePool's tokens
    MockERC20 internal a1;
    MockERC20 internal u0; // the Uniswap pair's tokens (separate, so balances never mix)
    MockERC20 internal u1;
    SimplePool internal pool;
    IUniswapV2PairLike internal uni;

    /// The pair asks its factory (this test contract) whether the protocol fee is switched on. It is not.
    function feeTo() external pure returns (address) {
        return address(0);
    }

    function setUp() public {
        a0 = new MockERC20(18);
        a1 = new MockERC20(6);
        u0 = new MockERC20(18);
        u1 = new MockERC20(6);
        pool = new SimplePool(IERC20(address(a0)), IERC20(address(a1)), "LP", "LP");
        uni = IUniswapV2PairLike(deployCode("out/UniswapV2Pair.sol/UniswapV2Pair.json"));
        uni.initialize(address(u0), address(u1));
        a0.mint(address(this), 1e40);
        a1.mint(address(this), 1e40);
        u0.mint(address(this), 1e40);
        u1.mint(address(this), 1e40);
        a0.approve(address(pool), type(uint256).max);
        a1.approve(address(pool), type(uint256).max);
    }

    function _assertSameState() internal view {
        (uint112 r0, uint112 r1,) = uni.getReserves();
        assertEq(pool.reserve0(), r0, "reserve0");
        assertEq(pool.reserve1(), r1, "reserve1");
        assertEq(pool.totalSupply(), uni.totalSupply(), "LP supply");
    }

    function _seed(uint256 x, uint256 y) internal {
        (,, uint256 mine) = pool.addLiquidity(x, y, 0);
        u0.transfer(address(uni), x);
        u1.transfer(address(uni), y);
        assertEq(uni.mint(address(this)), mine, "first mint");
        _assertSameState();
    }

    function testFuzz_SameResultsAsUniswapV2(
        uint8[16] memory ops,
        uint96[16] memory amounts,
        uint96 seed0,
        uint96 seed1,
        bool equalStart
    ) public {
        uint256 x = bound(seed0, 1e6, 1e26);
        uint256 y = equalStart ? x : bound(seed1, 1e6, 1e26); // equal reserves are a known edge case
        if (x * y <= 1e6) return;
        _seed(x, y);

        for (uint256 i = 0; i < ops.length; i++) {
            uint256 amount = bound(amounts[i], 1, 1e26);
            uint256 op = ops[i] % 4;
            if (op <= 1) {
                bool zeroForOne = op == 0;
                try pool.swap(zeroForOne ? address(a0) : address(a1), amount, 0, block.timestamp) returns (
                    uint256 out
                ) {
                    (zeroForOne ? u0 : u1).transfer(address(uni), amount);
                    // Uniswap's own K check must accept the amount SimplePool paid out
                    uni.swap(zeroForOne ? 0 : out, zeroForOne ? out : 0, address(this), "");
                } catch {}
            } else if (op == 2) {
                try pool.addLiquidity(amount, amount, 0) returns (uint256 d0, uint256 d1, uint256 shares) {
                    u0.transfer(address(uni), d0);
                    u1.transfer(address(uni), d1);
                    assertEq(uni.mint(address(this)), shares, "mint");
                } catch {}
            } else {
                uint256 shares = bound(amount, 1, pool.balanceOf(address(this)));
                try pool.removeLiquidity(shares, 0, 0) returns (uint256 o0, uint256 o1) {
                    uni.transfer(address(uni), shares);
                    (uint256 q0, uint256 q1) = uni.burn(address(this));
                    assertEq(q0, o0, "burn amount0");
                    assertEq(q1, o1, "burn amount1");
                } catch {}
            }
            _assertSameState();
        }
    }

    /// SimplePool pays out the largest amount Uniswap's K check allows: one unit more is rejected.
    function testFuzz_OneUnitMoreOut_FailsUniswapsKCheck(uint96 seed0, uint96 seed1, uint96 amountIn, bool zeroForOne)
        public
    {
        uint256 x = bound(seed0, 1e9, 1e26);
        uint256 y = bound(seed1, 1e9, 1e26);
        uint256 amount = bound(amountIn, 1, 1e26);
        _seed(x, y);
        (uint256 rIn, uint256 rOut) = zeroForOne ? (x, y) : (y, x);
        uint256 out = pool.getAmountOut(amount, rIn, rOut);
        vm.assume(out > 0 && out + 1 < rOut);

        (zeroForOne ? u0 : u1).transfer(address(uni), amount);
        vm.expectRevert(bytes("UniswapV2: K"));
        uni.swap(zeroForOne ? 0 : out + 1, zeroForOne ? out + 1 : 0, address(this), "");
        uni.swap(zeroForOne ? 0 : out, zeroForOne ? out : 0, address(this), ""); // the exact amount passes
    }
}
