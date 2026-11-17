// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SimplePool} from "../src/SimplePool.sol";
import {SimpleTwapOracle} from "../src/SimpleTwapOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Random sequences of adds, removes, swaps and direct donations. Calls that revert are simply undone.
contract PoolHandler is Test {
    SimplePool pool;
    MockERC20 t0;
    MockERC20 t1;
    address[] actors;
    bool public ghostKDropped;
    bool public ghostRemovedTooMuch;
    uint256 public swaps;
    uint256 public adds;
    uint256 public removes;
    uint256 public ghostDonated0;
    uint256 public ghostDonated1;

    // oracle tracking: every spot price that held for some time since the oracle's last update
    SimpleTwapOracle public oracle;
    uint256 public minPrice0 = type(uint256).max;
    uint256 public maxPrice0;
    bool public ghostTwapOutsideRange; // an average fell outside the lowest..highest price that held
    bool public ghostAccumulatorWentBack; // a running total decreased (no wrap is possible in these runs)
    uint256 public updates;

    constructor(SimplePool p, MockERC20 a, MockERC20 b, address[] memory ac) {
        pool = p;
        t0 = a;
        t1 = b;
        actors = ac;
    }

    /// Called once from setUp. The fuzzer can call it too, so later calls are ignored.
    function setOracle(SimpleTwapOracle o) external {
        if (address(oracle) != address(0)) return;
        oracle = o;
        _resetRange();
    }

    function _spot0() internal view returns (uint256) {
        return pool.reserve1() * 2 ** 112 / pool.reserve0();
    }

    function _resetRange() internal {
        minPrice0 = _spot0();
        maxPrice0 = minPrice0;
    }

    /// Before an action changes the price, the current price is one that "held" for the time just passed.
    modifier tracked() {
        uint256 p = _spot0();
        if (p < minPrice0) minPrice0 = p;
        if (p > maxPrice0) maxPrice0 = p;
        uint256 c0 = pool.price0CumulativeLast();
        uint256 c1 = pool.price1CumulativeLast();
        _;
        if (pool.price0CumulativeLast() < c0 || pool.price1CumulativeLast() < c1) ghostAccumulatorWentBack = true;
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 1 hours));
    }

    function updateOracle(uint256 extra) external tracked {
        // jump to the end of the period (plus a little) so most calls succeed; the current price is
        // what holds during the jump, and `tracked` already recorded it
        uint256 due = oracle.timestampLast() + oracle.PERIOD();
        if (block.timestamp < due) vm.warp(due + bound(extra, 0, 600));
        oracle.update();
        uint256 avg = oracle.price0Average();
        if (avg < minPrice0 || avg > maxPrice0) ghostTwapOutsideRange = true;
        updates++;
        _resetRange();
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function add(uint256 s, uint256 x, uint256 y) external tracked {
        x = bound(x, 1, 1e24);
        y = bound(y, 1, 1e24);
        vm.prank(_actor(s));
        pool.addLiquidity(x, y, 0);
        adds++;
    }

    function remove(uint256 s, uint256 sh) external tracked {
        address who = _actor(s);
        sh = bound(sh, 1, pool.balanceOf(who) == 0 ? 1 : pool.balanceOf(who));
        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        uint256 supply = pool.totalSupply();
        vm.prank(who);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(sh, 0, 0);
        if (a0 * supply > sh * r0 || a1 * supply > sh * r1) ghostRemovedTooMuch = true;
        removes++;
    }

    /// Tokens sent straight to the pool are not counted in the reserves (they stay in the pool).
    function donate(uint256 x, bool zero) external {
        x = bound(x, 0, 1e20);
        (zero ? t0 : t1).mint(address(pool), x);
        if (zero) ghostDonated0 += x;
        else ghostDonated1 += x;
    }

    function swap(uint256 s, uint256 x, bool zeroForOne) external tracked {
        x = bound(x, 1, 1e24);
        uint256 k = pool.reserve0() * pool.reserve1();
        vm.prank(_actor(s));
        pool.swap(zeroForOne ? address(t0) : address(t1), x, 0, block.timestamp);
        if (pool.reserve0() * pool.reserve1() < k) ghostKDropped = true;
        swaps++;
    }
}

contract SimplePoolInvariantTest is Test {
    SimplePool pool;
    MockERC20 t0;
    MockERC20 t1;
    PoolHandler h;
    address[] actors;

    function setUp() public {
        t0 = new MockERC20(18);
        t1 = new MockERC20(6);
        pool = new SimplePool(IERC20(address(t0)), IERC20(address(t1)), "LP", "LP");
        for (uint256 i; i < 3; i++) {
            address a = makeAddr(string.concat("a", vm.toString(i)));
            actors.push(a);
            t0.mint(a, 1e30);
            t1.mint(a, 1e30);
            vm.startPrank(a);
            t0.approve(address(pool), type(uint256).max);
            t1.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(actors[0]);
        pool.addLiquidity(1e21, 3e12, 0);
        h = new PoolHandler(pool, t0, t1, actors);
        h.setOracle(new SimpleTwapOracle(pool));
        targetContract(address(h));
    }

    /// Every token the pool holds is either in its reserves or was donated to it.
    function invariant_BalancesEqualReservesPlusDonations() public view {
        assertEq(t0.balanceOf(address(pool)), pool.reserve0() + h.ghostDonated0());
        assertEq(t1.balanceOf(address(pool)), pool.reserve1() + h.ghostDonated1());
    }

    /// v2: a time-weighted average can never be lower than the lowest price, or higher than the
    /// highest price, that actually held during its period.
    function invariant_TwapStaysWithinThePricesThatHeld() public view {
        assertFalse(h.ghostTwapOutsideRange());
    }

    function invariant_RunningTotalsNeverGoBack() public view {
        assertFalse(h.ghostAccumulatorWentBack());
    }

    function invariant_KNeverDropsOnSwap() public view {
        assertFalse(h.ghostKDropped());
    }

    function invariant_RemoveNeverPaysMoreThanTheShare() public view {
        assertFalse(h.ghostRemovedTooMuch());
    }

    function invariant_MinimumLiquidityStaysLocked() public view {
        assertEq(pool.balanceOf(pool.DEAD()), 1_000);
        assertGt(pool.reserve0(), 0);
        assertGt(pool.reserve1(), 0);
    }

    function invariant_SupplyEqualsSumOfBalances() public view {
        uint256 sum = pool.balanceOf(pool.DEAD());
        for (uint256 i; i < actors.length; i++) {
            sum += pool.balanceOf(actors[i]);
        }
        assertEq(pool.totalSupply(), sum);
    }
}
