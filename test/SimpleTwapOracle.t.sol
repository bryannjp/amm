// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SimplePool} from "../src/SimplePool.sol";
import {SimpleTwapOracle} from "../src/SimpleTwapOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// v2: the pool's price accumulators and the TWAP oracle that reads them.
contract SimpleTwapOracleTest is Test {
    MockERC20 internal weth;
    MockERC20 internal usdc;
    SimplePool internal pool;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant E = 1e18;
    uint256 internal constant U = 1e6;
    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant Q112 = 2 ** 112;
    /// 300,000 USDC / 100 ETH in raw units, times 2^112: the pool's starting price0
    uint256 internal constant P0 = 300_000 * U * Q112 / (100 * E);
    /// 100 ETH / 300,000 USDC in raw units, times 2^112: the pool's starting price1
    uint256 internal constant P1 = 100 * E * Q112 / (300_000 * U);

    event OracleUpdated(uint256 price0Average, uint256 price1Average, uint256 elapsed);

    function setUp() public {
        vm.warp(T0);
        weth = new MockERC20(18);
        usdc = new MockERC20(6);
        pool = new SimplePool(IERC20(address(weth)), IERC20(address(usdc)), "Simple LP", "SLP");
        address[3] memory users = [alice, bob, attacker];
        for (uint256 i = 0; i < users.length; i++) {
            weth.mint(users[i], 1e30);
            usdc.mint(users[i], 1e30);
            vm.startPrank(users[i]);
            weth.approve(address(pool), type(uint256).max);
            usdc.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(alice);
        pool.addLiquidity(100 * E, 300_000 * U, 0); // price 3,000 USDC per ETH
    }

    // ------------------------------------------------------------------ helpers

    function _swap(address who, address tokenIn, uint256 amountIn) internal returns (uint256) {
        vm.prank(who);
        return pool.swap(tokenIn, amountIn, 0, block.timestamp);
    }

    function _wait(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
    }

    function _consultEth(SimpleTwapOracle oracle, uint256 amount) internal view returns (uint256) {
        return oracle.consult(IERC20(address(weth)), amount);
    }

    // ------------------------------------------------------------------ pool: the accumulators

    function test_Accumulator_StartsAtZero_FirstDepositAddsNothing() public view {
        assertEq(pool.price0CumulativeLast(), 0);
        assertEq(pool.price1CumulativeLast(), 0);
        assertEq(pool.blockTimestampLast(), T0);
    }

    function test_Accumulator_AddsTheOldPriceTimesSeconds() public {
        _wait(100);
        _swap(bob, address(weth), 1 * E);
        // the price BEFORE the swap held for those 100 seconds
        assertEq(pool.price0CumulativeLast(), P0 * 100);
        assertEq(pool.price1CumulativeLast(), P1 * 100);
        assertEq(pool.blockTimestampLast(), T0 + 100);
    }

    function test_Accumulator_SameSecondAddsNothingMore() public {
        _wait(100);
        _swap(bob, address(weth), 1 * E);
        uint256 c0 = pool.price0CumulativeLast();
        _swap(bob, address(weth), 1 * E); // same second
        assertEq(pool.price0CumulativeLast(), c0);
    }

    function test_Accumulator_UpdatedByAddAndRemoveToo() public {
        _wait(10);
        vm.prank(alice);
        pool.addLiquidity(1 * E, 3_000 * U, 0);
        assertEq(pool.price0CumulativeLast(), P0 * 10);

        _wait(20);
        uint256 price = pool.reserve1() * Q112 / pool.reserve0();
        vm.prank(alice);
        pool.removeLiquidity(1e9, 0, 0);
        assertEq(pool.price0CumulativeLast(), P0 * 10 + price * 20);
    }

    function test_Accumulator_UsesTheNewPriceForTheNextPeriod() public {
        _wait(100);
        _swap(bob, address(weth), 10 * E);
        uint256 newPrice = pool.reserve1() * Q112 / pool.reserve0();
        _wait(50);
        _swap(bob, address(usdc), 1_000 * U);
        assertEq(pool.price0CumulativeLast(), P0 * 100 + newPrice * 50);
    }

    // ------------------------------------------------------------------ pool: currentCumulativePrices

    function test_Current_IncludesTimeSinceTheLastTrade_WithoutWriting() public {
        _wait(100);
        (uint256 c0, uint256 c1, uint256 t) = pool.currentCumulativePrices();
        assertEq(c0, P0 * 100);
        assertEq(c1, P1 * 100);
        assertEq(t, T0 + 100);
        assertEq(pool.price0CumulativeLast(), 0); // nothing stored
        assertEq(pool.blockTimestampLast(), T0);
    }

    /// Regression test for the review: in the same second as a trade it returned (0, 0, 0).
    function test_Current_SameSecondAsATrade_ReturnsTheStoredTotalsAndNow() public {
        _wait(100);
        _swap(bob, address(weth), 1 * E);
        (uint256 c0, uint256 c1, uint256 t) = pool.currentCumulativePrices();
        assertEq(c0, pool.price0CumulativeLast());
        assertEq(c1, pool.price1CumulativeLast());
        assertEq(t, block.timestamp);
        assertGt(c0, 0);
    }

    function test_Current_EmptyPool_ReturnsZeroTotalsAndNow() public {
        SimplePool empty = new SimplePool(IERC20(address(weth)), IERC20(address(usdc)), "LP", "LP");
        _wait(500);
        (uint256 c0, uint256 c1, uint256 t) = empty.currentCumulativePrices();
        assertEq(c0, 0);
        assertEq(c1, 0);
        assertEq(t, block.timestamp);
    }

    // ------------------------------------------------------------------ pool: the uint112 reserve cap

    function test_RevertWhen_AddPushesAReserveAbove2Pow112() public {
        MockERC20 a = new MockERC20(18);
        MockERC20 b = new MockERC20(18);
        SimplePool p = new SimplePool(IERC20(address(a)), IERC20(address(b)), "LP", "LP");
        a.mint(address(this), type(uint128).max);
        b.mint(address(this), type(uint128).max);
        a.approve(address(p), type(uint256).max);
        b.approve(address(p), type(uint256).max);

        vm.expectRevert(SimplePool.Pool__ReserveOverflow.selector);
        p.addLiquidity(uint256(type(uint112).max) + 1, 1e18, 0);
        vm.expectRevert(SimplePool.Pool__ReserveOverflow.selector);
        p.addLiquidity(1e18, uint256(type(uint112).max) + 1, 0);
        p.addLiquidity(type(uint112).max, 1e18, 0); // exactly the cap is allowed
    }

    function test_RevertWhen_SwapPushesAReserveAbove2Pow112() public {
        MockERC20 a = new MockERC20(18);
        MockERC20 b = new MockERC20(18);
        SimplePool p = new SimplePool(IERC20(address(a)), IERC20(address(b)), "LP", "LP");
        a.mint(address(this), type(uint128).max);
        b.mint(address(this), type(uint128).max);
        a.approve(address(p), type(uint256).max);
        b.approve(address(p), type(uint256).max);
        p.addLiquidity(type(uint112).max - 10, 1e18, 0);

        vm.expectRevert(SimplePool.Pool__ReserveOverflow.selector);
        p.swap(address(a), 1e30, 0, block.timestamp);
    }

    // ------------------------------------------------------------------ oracle: deployment

    function test_Oracle_Constructor_StoresTokensAndTheFirstReading() public {
        _wait(100);
        SimpleTwapOracle oracle = new SimpleTwapOracle(pool);
        assertEq(address(oracle.token0()), address(weth));
        assertEq(address(oracle.token1()), address(usdc));
        assertEq(oracle.price0CumulativeLast(), P0 * 100);
        assertEq(oracle.price1CumulativeLast(), P1 * 100);
        assertEq(oracle.timestampLast(), T0 + 100);
        assertEq(oracle.PERIOD(), 30 minutes);
    }

    function test_RevertWhen_OracleOnAnEmptyPool() public {
        SimplePool empty = new SimplePool(IERC20(address(weth)), IERC20(address(usdc)), "LP", "LP");
        vm.expectRevert(SimpleTwapOracle.Oracle__NoLiquidity.selector);
        new SimpleTwapOracle(empty);
    }

    function test_RevertWhen_ConsultBeforeTheFirstUpdate() public {
        SimpleTwapOracle oracle = new SimpleTwapOracle(pool);
        vm.expectRevert(SimpleTwapOracle.Oracle__NotReady.selector);
        _consultEth(oracle, 1 * E);
    }

    // ------------------------------------------------------------------ oracle: update

    function test_Update_OnlyAfterAFullPeriod_1799Fails_1800Works() public {
        SimpleTwapOracle oracle = new SimpleTwapOracle(pool);
        _wait(1_799);
        vm.expectRevert(abi.encodeWithSelector(SimpleTwapOracle.Oracle__PeriodNotElapsed.selector, 1_799, 1_800));
        oracle.update();
        _wait(1);
        vm.expectEmit(false, false, false, true, address(oracle));
        emit OracleUpdated(P0, P1, 1_800);
        oracle.update();
    }

    function test_Update_SavesTheReading_NextPeriodStartsFromIt() public {
        SimpleTwapOracle oracle = new SimpleTwapOracle(pool);
        _wait(1_800);
        oracle.update();
        (uint256 c0, uint256 c1, uint256 t) = pool.currentCumulativePrices();
        assertEq(oracle.price0CumulativeLast(), c0);
        assertEq(oracle.price1CumulativeLast(), c1);
        assertEq(oracle.timestampLast(), t);

        _wait(1_000);
        vm.expectRevert(abi.encodeWithSelector(SimpleTwapOracle.Oracle__PeriodNotElapsed.selector, 1_000, 1_800));
        oracle.update(); // measured from the last update, not from deployment
    }

    /// Regression test for the review: a trade and an update in the same second used to revert.
    function test_Update_InTheSameSecondAsATrade() public {
        SimpleTwapOracle oracle = new SimpleTwapOracle(pool);
        _wait(1_800);
        _swap(bob, address(weth), 1 * E);
        oracle.update();
        assertEq(oracle.price0Average(), P0); // the whole period was at the old price
    }

    /// Regression test for the review: an oracle deployed right after a trade stored timestamp 0.
    function test_Oracle_DeployedInTheSameSecondAsATrade() public {
        SimpleTwapOracle oracle = new SimpleTwapOracle(pool); // same second as the deposit
        assertEq(oracle.timestampLast(), T0);
        _wait(1_800);
        oracle.update();
        assertEq(_consultEth(oracle, 1 * E), 2_999_999_999);
    }

    // ------------------------------------------------------------------ oracle: consult

    function test_Consult_BothDirections() public {
        SimpleTwapOracle oracle = new SimpleTwapOracle(pool);
        _wait(1_800);
        oracle.update();
        assertEq(_consultEth(oracle, 1 * E), 2_999_999_999); // 2,999.999999 USDC (floor rounding)
        assertEq(oracle.consult(IERC20(address(usdc)), 3_000 * U), 999_999_999_999_999_999); // ~1 ETH
    }

    function test_RevertWhen_ConsultAnotherToken() public {
        SimpleTwapOracle oracle = new SimpleTwapOracle(pool);
        _wait(1_800);
        oracle.update();
        vm.expectRevert(abi.encodeWithSelector(SimpleTwapOracle.Oracle__InvalidToken.selector, address(0xBEEF)));
        oracle.consult(IERC20(address(0xBEEF)), 1);
    }

    function test_Twap_IsTheTimeWeightedAverage() public {
        // the 2,000 / 2,100 / 1,950 timeline from the explanation, shaped with real swaps:
        // 1,200 s at the starting price, then two moves, 300 s each
        SimpleTwapOracle oracle = new SimpleTwapOracle(pool);
        _wait(1_200);
        _swap(bob, address(usdc), 5_000 * U);
        uint256 priceB = pool.reserve1() * Q112 / pool.reserve0();
        _wait(300);
        _swap(bob, address(weth), 4 * E);
        uint256 priceC = pool.reserve1() * Q112 / pool.reserve0();
        _wait(300);
        oracle.update();
        assertEq(oracle.price0Average(), (P0 * 1_200 + priceB * 300 + priceC * 300) / 1_800);
    }

    // ------------------------------------------------------------------ manipulation

    function test_Manipulation_SameTransaction_DoesNotMoveTheTwapAtAll() public {
        SimpleTwapOracle oracle = new SimpleTwapOracle(pool);
        _wait(1_800);
        // pump and dump inside the same second: the fake price is counted for 0 seconds
        uint256 got = _swap(attacker, address(weth), 50 * E);
        _swap(attacker, address(usdc), got);
        oracle.update();
        assertEq(oracle.price0Average(), P0);
    }

    function test_Manipulation_OneBlock_MovesTheTwapOnlySlightly() public {
        SimpleTwapOracle oracle = new SimpleTwapOracle(pool);
        _wait(1_800 - 12);
        uint256 got = _swap(attacker, address(weth), 50 * E); // dump 12 s before the update
        uint256 spot = pool.reserve1() * 1e12 / pool.reserve0(); // USDC per ETH, whole units
        _wait(12);
        oracle.update();
        uint256 twap = _consultEth(oracle, 1 * E);

        assertEq(spot, 1_334); // spot fell 55%
        assertEq(twap, 2_988_897_786); // 2,988.90 USDC: the 30-minute average fell 0.37%
        vm.prank(attacker);
        uint256 back = pool.swap(address(usdc), got, 0, block.timestamp);
        assertEq(50 * E - back, 200_099_599_298_498_503); // the round trip cost the attacker ~0.2 ETH
    }

    // ------------------------------------------------------------------ wrap-around (the odometer rolls over)

    function test_Wrap_OracleStillWorksWhenTheTotalRollsOverDuringAPeriod() public {
        // put price0's running total 1,000 seconds' worth below 2^256 (price0CumulativeLast is storage slot 7)
        vm.store(address(pool), bytes32(uint256(7)), bytes32(type(uint256).max - P0 * 1_000));
        assertEq(pool.price0CumulativeLast(), type(uint256).max - P0 * 1_000);

        SimpleTwapOracle oracle = new SimpleTwapOracle(pool);
        _wait(1_800); // the total wraps past 2^256 inside this period, with no trade in between
        oracle.update();
        assertEq(oracle.price0Average(), P0);
        assertEq(_consultEth(oracle, 1 * E), 2_999_999_999);

        _swap(bob, address(weth), 1 * E); // the pool itself wraps too and keeps working
        assertLt(pool.price0CumulativeLast(), type(uint256).max - P0 * 1_000);
    }
}
