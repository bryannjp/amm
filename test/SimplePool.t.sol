// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SimplePool} from "../src/SimplePool.sol";
import {MockERC20, SnoopingToken, ReentrantToken} from "./mocks/MockERC20.sol";

contract SimplePoolTest is Test {
    MockERC20 internal weth;
    MockERC20 internal usdc;
    SimplePool internal pool;

    address internal alice = makeAddr("alice"); // first liquidity provider
    address internal bob = makeAddr("bob"); // trader
    address internal frank = makeAddr("frank"); // second liquidity provider

    uint256 internal constant E = 1e18;
    uint256 internal constant U = 1e6;
    uint256 internal constant ERIN_SHARES = 219_089_023_001_066; // sqrt(4e18 * 12_000e6) - 1_000

    // declared locally so a wrong `indexed` or argument order in the contract is caught
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 mintedShares);
    event LiquidityRemoved(address indexed taker, uint256 amount0, uint256 amount1, uint256 burnedShares);
    event Swap(address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    function setUp() public {
        weth = new MockERC20(18);
        usdc = new MockERC20(6);
        pool = new SimplePool(IERC20(address(weth)), IERC20(address(usdc)), "Simple LP", "SLP");
        address[3] memory users = [alice, bob, frank];
        for (uint256 i = 0; i < users.length; i++) {
            weth.mint(users[i], 1e30);
            usdc.mint(users[i], 1e30);
            vm.startPrank(users[i]);
            weth.approve(address(pool), type(uint256).max);
            usdc.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------ helpers

    function _add(address who, uint256 a0, uint256 a1) internal returns (uint256 used0, uint256 used1, uint256 shares) {
        vm.prank(who);
        return pool.addLiquidity(a0, a1, 0);
    }

    function _swap(address who, address tokenIn, uint256 amountIn) internal returns (uint256) {
        vm.prank(who);
        return pool.swap(tokenIn, amountIn, 0, block.timestamp);
    }

    /// The example pool from the explanation: 100 ETH + 300,000 USDC, price 3,000.
    function _seed() internal returns (uint256 shares) {
        (,, shares) = _add(alice, 100 * E, 300_000 * U);
    }

    function _slippage(uint256 actual, uint256 minimum) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SimplePool.Pool__SlippageExceeded.selector, actual, minimum);
    }

    function _assertReservesMatchBalances() internal view {
        assertEq(pool.reserve0(), weth.balanceOf(address(pool)), "reserve0 != balance");
        assertEq(pool.reserve1(), usdc.balanceOf(address(pool)), "reserve1 != balance");
    }

    // ------------------------------------------------------------------ constructor

    function test_Constructor_SetsTokensAndMetadata() public view {
        assertEq(address(pool.token0()), address(weth));
        assertEq(address(pool.token1()), address(usdc));
        assertEq(pool.name(), "Simple LP");
        assertEq(pool.symbol(), "SLP");
        assertEq(pool.MINIMUM_LIQUIDITY(), 1_000);
        assertEq(pool.DEAD(), address(0xdead));
    }

    function test_RevertWhen_EitherTokenIsZero() public {
        vm.expectRevert(SimplePool.Pool__ZeroAddress.selector);
        new SimplePool(IERC20(address(0)), IERC20(address(usdc)), "LP", "LP");
        vm.expectRevert(SimplePool.Pool__ZeroAddress.selector);
        new SimplePool(IERC20(address(weth)), IERC20(address(0)), "LP", "LP");
    }

    function test_RevertWhen_TokensAreIdentical() public {
        vm.expectRevert(SimplePool.Pool__IdenticalTokens.selector);
        new SimplePool(IERC20(address(weth)), IERC20(address(weth)), "LP", "LP");
    }

    // ------------------------------------------------------------------ addLiquidity: the first deposit

    function test_FirstDeposit_SharesAreSqrtMinus1000_And1000AreLocked() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit LiquidityAdded(alice, 4 * E, 12_000 * U, ERIN_SHARES);
        (uint256 a0, uint256 a1, uint256 shares) = _add(alice, 4 * E, 12_000 * U);

        assertEq(a0, 4 * E);
        assertEq(a1, 12_000 * U);
        assertEq(shares, ERIN_SHARES);
        assertEq(pool.balanceOf(alice), ERIN_SHARES);
        assertEq(pool.balanceOf(pool.DEAD()), 1_000);
        assertEq(pool.totalSupply(), ERIN_SHARES + 1_000);
        assertEq(pool.reserve0(), 4 * E);
        assertEq(pool.reserve1(), 12_000 * U);
        _assertReservesMatchBalances();
    }

    function test_RevertWhen_FirstDepositRootIsExactly1000() public {
        vm.prank(alice);
        vm.expectRevert(SimplePool.Pool__InsufficientInitialLiquidity.selector);
        pool.addLiquidity(1_000, 1_000, 0); // sqrt = 1,000: nothing left after locking
    }

    function test_FirstDeposit_RootOf1001_GivesOneShare() public {
        (,, uint256 shares) = _add(alice, 1_001, 1_001);
        assertEq(shares, 1);
    }

    function test_RevertWhen_FirstDepositBelowMinShares() public {
        vm.prank(alice);
        vm.expectRevert(_slippage(ERIN_SHARES, ERIN_SHARES + 1));
        pool.addLiquidity(4 * E, 12_000 * U, ERIN_SHARES + 1);
    }

    function test_RevertWhen_AddWithAZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(SimplePool.Pool__ZeroAmount.selector);
        pool.addLiquidity(0, 1, 0);
        vm.expectRevert(SimplePool.Pool__ZeroAmount.selector);
        pool.addLiquidity(1, 0, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ addLiquidity: later deposits

    function test_LaterDeposit_EthSideDecides_TakesOnlyTheMatchingUsdc() public {
        _add(alice, 4 * E, 12_000 * U);
        uint256 frankUsdcBefore = usdc.balanceOf(frank);

        vm.expectEmit(true, false, false, true, address(pool));
        emit LiquidityAdded(frank, 1 * E, 3_000 * U, 54_772_255_750_516);
        (uint256 a0, uint256 a1, uint256 shares) = _add(frank, 1 * E, 5_000 * U);

        assertEq(a0, 1 * E);
        assertEq(a1, 3_000 * U); // not 5,000
        assertEq(shares, 54_772_255_750_516); // a quarter of the supply before = 20% after
        assertEq(usdc.balanceOf(frank), frankUsdcBefore - 3_000 * U);
        assertEq(pool.totalSupply(), 273_861_278_752_582);
        _assertReservesMatchBalances();
    }

    function test_LaterDeposit_UsdcSideDecides_TakesOnlyTheMatchingEth() public {
        _add(alice, 5 * E, 15_000 * U);
        (uint256 a0, uint256 a1, uint256 shares) = _add(frank, 2 * E, 3_000 * U);

        assertEq(a0, 1 * E); // not 2
        assertEq(a1, 3_000 * U);
        assertApproxEqAbs(shares * 6, pool.totalSupply(), 6); // one sixth of the pool after (floor rounding)
        _assertReservesMatchBalances();
    }

    function test_LaterDeposit_NeverMovesThePrice() public {
        _seed();
        _swap(bob, address(weth), 7 * E);
        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        _add(frank, 3 * E, 1e30);
        // reserve1/reserve0 is unchanged up to one unit of rounding
        assertApproxEqAbs(pool.reserve1() * r0, r1 * pool.reserve0(), pool.reserve0());
    }

    function test_LaterDeposit_DoesNotDiluteEarlierProviders() public {
        uint256 aliceShares = _seed();
        uint256 aliceUsdcBefore = aliceShares * pool.reserve1() / pool.totalSupply();
        _add(frank, 33 * E, 1e30);
        assertGe(aliceShares * pool.reserve1() / pool.totalSupply(), aliceUsdcBefore);
    }

    /// When the matching amount equals what was offered exactly, the offered ETH is used as is.
    function test_LaterDeposit_ExactMatchAfterRounding_KeepsTheOfferedEth() public {
        _add(alice, 4 * E, 12_000 * U);
        // (1 ETH + 1 wei) matches 3,000 USDC after rounding down, which is exactly what is offered
        (uint256 a0, uint256 a1,) = _add(frank, 1 * E + 1, 3_000 * U);
        assertEq(a0, 1 * E + 1);
        assertEq(a1, 3_000 * U);
    }

    function test_LaterDeposit_ExactlyMinShares_Works() public {
        _add(alice, 4 * E, 12_000 * U);
        vm.prank(frank);
        (,, uint256 shares) = pool.addLiquidity(1 * E, 3_000 * U, 54_772_255_750_516);
        assertEq(shares, 54_772_255_750_516);
    }

    function test_RevertWhen_LaterDepositBelowMinShares() public {
        _add(alice, 4 * E, 12_000 * U);
        vm.prank(frank);
        vm.expectRevert(_slippage(54_772_255_750_516, 54_772_255_750_517));
        pool.addLiquidity(1 * E, 3_000 * U, 54_772_255_750_517);
    }

    function test_RevertWhen_LaterDepositIsTooSmallForOneShare() public {
        _add(alice, 4 * E, 12_000 * U);
        vm.prank(frank);
        vm.expectRevert(SimplePool.Pool__ZeroAmount.selector);
        pool.addLiquidity(1, 1, 0); // 1 wei of ETH buys 0 shares
    }

    function test_RevertWhen_AddWithoutApproval() public {
        _seed();
        address dave = makeAddr("dave");
        weth.mint(dave, 1 * E);
        usdc.mint(dave, 3_000 * U);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, 1 * E)
        );
        pool.addLiquidity(1 * E, 3_000 * U, 0);
    }

    // ------------------------------------------------------------------ removeLiquidity

    function test_Remove_PaysTheShareOfBothReserves() public {
        _add(alice, 4 * E, 12_000 * U);
        (,, uint256 shares) = _add(frank, 1 * E, 3_000 * U);
        uint256 w = weth.balanceOf(frank);
        uint256 u = usdc.balanceOf(frank);
        uint256 expect0 = shares * pool.reserve0() / pool.totalSupply();
        uint256 expect1 = shares * pool.reserve1() / pool.totalSupply();

        vm.expectEmit(true, false, false, true, address(pool));
        emit LiquidityRemoved(frank, expect0, expect1, shares);
        vm.prank(frank);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(shares, 0, 0);

        assertEq(a0, expect0);
        assertEq(a1, expect1);
        // his shares were rounded down when he joined, so he gets back a hair less than 1 ETH + 3,000 USDC
        assertEq(a0, 999_999_999_999_992_697);
        assertLe(a1, 3_000 * U);
        assertApproxEqAbs(a1, 3_000 * U, 1);
        assertEq(weth.balanceOf(frank), w + a0);
        assertEq(usdc.balanceOf(frank), u + a1);
        assertEq(pool.balanceOf(frank), 0);
        _assertReservesMatchBalances();
    }

    function test_Remove_AfterTrading_ReturnsMoreThanPutIn() public {
        uint256 shares = _seed();
        for (uint256 i = 0; i < 20; i++) {
            uint256 out = _swap(bob, address(weth), 10 * E);
            _swap(bob, address(usdc), out);
        }
        vm.prank(alice);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(shares, 0, 0);
        // value at 3,000 USDC/ETH, in USDC units with 18 decimals
        uint256 valueOut = a0 * 3_000 + a1 * 1e12;
        uint256 valueIn = 100 * E * 3_000 + 300_000 * U * 1e12;
        assertGt(valueOut, valueIn * 99_999 / 100_000); // minus the tiny locked part, fees put her ahead
        assertGt(a0, 100 * E);
    }

    function test_Remove_EveryoneCanLeave_The1000StayLocked() public {
        uint256 shares = _seed();
        vm.prank(alice);
        pool.removeLiquidity(shares, 0, 0);
        assertEq(pool.totalSupply(), 1_000);
        assertGt(pool.reserve0(), 0);
        assertGt(pool.reserve1(), 0);
        _assertReservesMatchBalances();
    }

    function test_RevertWhen_RemoveZeroShares() public {
        _seed();
        vm.prank(alice);
        vm.expectRevert(SimplePool.Pool__ZeroAmount.selector);
        pool.removeLiquidity(0, 0, 0);
    }

    function test_RevertWhen_RemoveRoundsAnAmountToZero() public {
        _add(alice, 1e18, 1e6); // 1 share is worth less than one unit of token1
        vm.prank(alice);
        vm.expectRevert(SimplePool.Pool__ZeroAmount.selector);
        pool.removeLiquidity(1, 0, 0);
    }

    function test_RevertWhen_RemoveBelowMinAmount0() public {
        uint256 shares = _seed();
        uint256 expected0 = shares * pool.reserve0() / pool.totalSupply();
        vm.prank(alice);
        vm.expectRevert(_slippage(expected0, expected0 + 1));
        pool.removeLiquidity(shares, expected0 + 1, 0);
    }

    function test_RevertWhen_RemoveBelowMinAmount1() public {
        uint256 shares = _seed();
        uint256 expected1 = shares * pool.reserve1() / pool.totalSupply();
        vm.prank(alice);
        vm.expectRevert(_slippage(expected1, expected1 + 1));
        pool.removeLiquidity(shares, 0, expected1 + 1);
    }

    function test_RevertWhen_RemoveMoreSharesThanOwned() public {
        uint256 shares = _seed();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, shares));
        pool.removeLiquidity(shares, 0, 0);
    }

    // ------------------------------------------------------------------ swap

    function test_Swap_1Eth_Gives2961Usdc() public {
        _seed();
        uint256 usdcBefore = usdc.balanceOf(bob);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Swap(bob, address(weth), 1 * E, 2_961_474_103);
        uint256 out = _swap(bob, address(weth), 1 * E);

        assertEq(out, 2_961_474_103);
        assertEq(usdc.balanceOf(bob), usdcBefore + out);
        assertEq(pool.reserve0(), 101 * E);
        assertEq(pool.reserve1(), 300_000 * U - out);
        _assertReservesMatchBalances();
    }

    function test_Swap_OtherDirection_UsdcForEth() public {
        _seed();
        uint256 out = _swap(bob, address(usdc), 3_000 * U);
        assertEq(out, pool.getAmountOut(3_000 * U, 300_000 * U, 100 * E) + 0);
        assertEq(out, 987_158_034_397_061_298); // just under 1 ETH: price impact plus fee
        assertEq(pool.reserve0(), 100 * E - out);
        assertEq(pool.reserve1(), 303_000 * U);
        _assertReservesMatchBalances();
    }

    function test_Swap_FeeMakesKGrow() public {
        _seed();
        uint256 kBefore = pool.reserve0() * pool.reserve1();
        _swap(bob, address(weth), 1 * E);
        assertGt(pool.reserve0() * pool.reserve1(), kBefore);
    }

    /// Regression test for the bug found in review: with equal reserves the direction was decided
    /// by comparing reserve values, so a token1-in swap updated the reserves as if token0 came in.
    function test_Swap_EqualReserves_BothDirections_KeepReservesCorrect() public {
        MockERC20 a = new MockERC20(18);
        MockERC20 b = new MockERC20(18);
        SimplePool p = new SimplePool(IERC20(address(a)), IERC20(address(b)), "LP", "LP");
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        a.approve(address(p), type(uint256).max);
        b.approve(address(p), type(uint256).max);
        p.addLiquidity(1_000 * E, 1_000 * E, 0);

        p.swap(address(b), 10 * E, 0, block.timestamp); // token1 in while reserves are equal
        assertEq(p.reserve0(), a.balanceOf(address(p)));
        assertEq(p.reserve1(), b.balanceOf(address(p)));
        assertEq(p.reserve1(), 1_010 * E);

        p.swap(address(a), 10 * E, 0, block.timestamp); // and token0 in
        assertEq(p.reserve0(), a.balanceOf(address(p)));
        assertEq(p.reserve1(), b.balanceOf(address(p)));
    }

    function test_RevertWhen_SwapBelowMinAmountOut() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(_slippage(2_961_474_103, 2_961_474_104));
        pool.swap(address(weth), 1 * E, 2_961_474_104, block.timestamp);
    }

    function test_Swap_ExactlyMinAmountOut_Works() public {
        _seed();
        vm.prank(bob);
        assertEq(pool.swap(address(weth), 1 * E, 2_961_474_103, block.timestamp), 2_961_474_103);
    }

    function test_Swap_DeadlineIsInclusive_ThenExpires() public {
        _seed();
        vm.warp(1_000_000);
        _swap(bob, address(weth), 1 * E); // deadline == now works
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SimplePool.Pool__Expired.selector, 999_999));
        pool.swap(address(weth), 1 * E, 0, 999_999);
    }

    function test_RevertWhen_SwapInvalidToken() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SimplePool.Pool__InvalidToken.selector, address(0xBEEF)));
        pool.swap(address(0xBEEF), 1, 0, block.timestamp);
    }

    function test_RevertWhen_SwapZeroIn() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(SimplePool.Pool__ZeroAmount.selector);
        pool.swap(address(weth), 0, 0, block.timestamp);
    }

    function test_RevertWhen_SwapTooSmallForAnyOutput() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(SimplePool.Pool__ZeroAmount.selector);
        pool.swap(address(weth), 1, 0, block.timestamp); // 1 wei of ETH buys 0 USDC units
    }

    function test_RevertWhen_SwapOnAnEmptyPool() public {
        vm.prank(bob);
        vm.expectRevert(SimplePool.Pool__ZeroAmount.selector);
        pool.swap(address(weth), 1 * E, 0, block.timestamp);
    }

    // ------------------------------------------------------------------ getAmountOut

    function test_GetAmountOut_UniswapNumbers() public view {
        assertEq(pool.getAmountOut(1 * E, 100 * E, 300_000 * U), 2_961_474_103);
        assertEq(pool.getAmountOut(10 * E, 100 * E, 300_000 * U), 27_198_326_816);
        assertEq(pool.getAmountOut(0, 100 * E, 300_000 * U), 0);
    }

    function testFuzz_GetAmountOut_NeverDrainsThePool(uint112 amountIn, uint112 reserveIn, uint112 reserveOut)
        public
        view
    {
        vm.assume(reserveIn > 0);
        assertLt(pool.getAmountOut(amountIn, reserveIn, reserveOut), uint256(reserveOut) + (reserveOut == 0 ? 1 : 0));
    }

    // ------------------------------------------------------------------ slippage protection stops a sandwich

    function test_Sandwich_FrontRunTriggersTheMinimum() public {
        _seed();
        uint256 quote = pool.getAmountOut(2 * E, pool.reserve0(), pool.reserve1());
        uint256 minOut = quote * 99 / 100; // 1% tolerance

        address attacker = makeAddr("attacker");
        weth.mint(attacker, 20 * E);
        vm.startPrank(attacker);
        weth.approve(address(pool), type(uint256).max);
        pool.swap(address(weth), 20 * E, 0, block.timestamp); // front-run
        vm.stopPrank();

        uint256 nowOut = pool.getAmountOut(2 * E, pool.reserve0(), pool.reserve1());
        vm.prank(bob);
        vm.expectRevert(_slippage(nowOut, minOut));
        pool.swap(address(weth), 2 * E, minOut, block.timestamp);
    }

    // ------------------------------------------------------------------ reserves are updated before tokens move

    function _snoopPool() internal returns (SnoopingToken snoop, SimplePool p) {
        snoop = new SnoopingToken();
        p = new SimplePool(IERC20(address(weth)), IERC20(address(snoop)), "LP", "LP");
        snoop.setPool(address(p));
        weth.mint(address(this), 1e30);
        snoop.mint(address(this), 1e30);
        weth.approve(address(p), type(uint256).max);
        snoop.approve(address(p), type(uint256).max);
        p.addLiquidity(100 * E, 300 * E, 0);
    }

    function test_Order_SwapPaysOutAfterUpdatingReserves() public {
        (SnoopingToken snoop, SimplePool p) = _snoopPool();
        p.swap(address(weth), 10 * E, 0, block.timestamp); // pays out the snooping token
        assertEq(snoop.reserve0WhenPaidOut(), p.reserve0()); // already 110, not the stale 100
        assertEq(snoop.reserve1WhenPaidOut(), p.reserve1());
    }

    function test_Order_SwapPullsInAfterUpdatingReserves() public {
        (SnoopingToken snoop, SimplePool p) = _snoopPool();
        p.swap(address(snoop), 30 * E, 0, block.timestamp); // pulls in the snooping token
        assertEq(snoop.reserve0WhenPulledIn(), p.reserve0());
        assertEq(snoop.reserve1WhenPulledIn(), p.reserve1());
    }

    function test_Order_RemovePaysOutAfterUpdatingReserves() public {
        (SnoopingToken snoop, SimplePool p) = _snoopPool();
        p.removeLiquidity(p.balanceOf(address(this)) / 2, 0, 0);
        assertEq(snoop.reserve0WhenPaidOut(), p.reserve0());
        assertEq(snoop.reserve1WhenPaidOut(), p.reserve1());
    }

    function test_Order_AddPullsInAfterUpdatingReserves() public {
        (SnoopingToken snoop, SimplePool p) = _snoopPool();
        p.addLiquidity(10 * E, 30 * E, 0);
        assertEq(snoop.reserve0WhenPulledIn(), p.reserve0());
        assertEq(snoop.reserve1WhenPulledIn(), p.reserve1());
    }

    // ------------------------------------------------------------------ reentrancy

    function _reentrantPool() internal returns (ReentrantToken bad, SimplePool p) {
        bad = new ReentrantToken();
        p = new SimplePool(IERC20(address(weth)), IERC20(address(bad)), "LP", "LP");
        weth.mint(address(this), 1e30);
        bad.mint(address(this), 1e30);
        bad.mint(address(bad), 1e30);
        weth.approve(address(p), type(uint256).max);
        bad.approve(address(p), type(uint256).max);
        p.addLiquidity(100 * E, 300 * E, 0); // not armed yet
    }

    function _assertBlocked(ReentrantToken bad) internal view {
        assertTrue(bad.attacked());
        assertEq(bad.revertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function test_Reentrancy_SwapCannotBeReenteredFromATransfer() public {
        (ReentrantToken bad, SimplePool p) = _reentrantPool();
        bad.arm(address(p), abi.encodeCall(SimplePool.swap, (address(weth), 1 * E, 0, block.timestamp)));
        p.swap(address(weth), 10 * E, 0, block.timestamp);
        _assertBlocked(bad);
    }

    function test_Reentrancy_AddCannotBeReentered() public {
        (ReentrantToken bad, SimplePool p) = _reentrantPool();
        bad.arm(address(p), abi.encodeCall(SimplePool.removeLiquidity, (1, 0, 0)));
        p.addLiquidity(1 * E, 3 * E, 0);
        _assertBlocked(bad);
    }

    function test_Reentrancy_RemoveCannotBeReentered() public {
        (ReentrantToken bad, SimplePool p) = _reentrantPool();
        bad.arm(address(p), abi.encodeCall(SimplePool.addLiquidity, (1 * E, 3 * E, 0)));
        p.removeLiquidity(1e18, 0, 0);
        _assertBlocked(bad);
    }
}
