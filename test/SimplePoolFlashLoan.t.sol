// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SimplePool} from "../src/SimplePool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

// ====================================================================== helpers for the liquidation story

/// A lending app with one under-water position: anyone may repay its 10,000 USDC debt and
/// receive its ETH collateral with a 5% bonus (10,000 / 2,000 = 5 ETH, + 5% = 5.25 ETH).
contract MockLendy {
    MockERC20 internal usdc;
    MockERC20 internal weth;

    constructor(MockERC20 usdc_, MockERC20 weth_) {
        usdc = usdc_;
        weth = weth_;
    }

    function liquidate() external {
        usdc.transferFrom(msg.sender, address(this), 10_000e6);
        weth.transfer(msg.sender, 5.25e18);
    }
}

/// Another exchange that buys ETH at a fixed price, minus a 0.3% fee.
contract MockDexB {
    MockERC20 internal usdc;
    MockERC20 internal weth;
    uint256 public pricePerEth; // in USDC units (6 decimals)

    constructor(MockERC20 usdc_, MockERC20 weth_, uint256 pricePerEth_) {
        usdc = usdc_;
        weth = weth_;
        pricePerEth = pricePerEth_;
    }

    function sellEth(uint256 amount) external returns (uint256 out) {
        weth.transferFrom(msg.sender, address(this), amount);
        out = amount * pricePerEth / 1e18 * 997 / 1000;
        usdc.transfer(msg.sender, out);
    }
}

/// Dave's contract: borrows USDC, liquidates on Lendy, sells the ETH on DEX B, repays.
contract Liquidator is IERC3156FlashBorrower {
    SimplePool internal pool;
    MockLendy internal lendy;
    MockDexB internal dex;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    constructor(SimplePool pool_, MockLendy lendy_, MockDexB dex_, MockERC20 usdc_, MockERC20 weth_) {
        pool = pool_;
        lendy = lendy_;
        dex = dex_;
        usdc = usdc_;
        weth = weth_;
    }

    function go() external {
        pool.flashLoan(this, address(usdc), 10_000e6, "");
    }

    function onFlashLoan(address initiator, address, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        require(msg.sender == address(pool), "untrusted lender");
        require(initiator == address(this), "untrusted initiator");
        usdc.approve(address(lendy), amount);
        lendy.liquidate(); // pay 10,000 USDC, receive 5.25 ETH
        weth.approve(address(dex), 5.25e18);
        dex.sellEth(5.25e18); // 5.25 ETH -> USDC on DEX B
        usdc.approve(address(pool), amount + fee); // let the pool take back 10,000 + 30
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

// ====================================================================== borrowers used to test the rules

/// The borrower template from the ERC-3156 spec: it only accepts loans it started itself.
contract StandardBorrower is IERC3156FlashBorrower {
    SimplePool internal pool;

    constructor(SimplePool pool_) {
        pool = pool_;
    }

    function borrow(address token, uint256 amount) external {
        pool.flashLoan(this, token, amount, "");
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        require(msg.sender == address(pool), "FlashBorrower: Untrusted lender");
        require(initiator == address(this), "FlashBorrower: Untrusted loan initiator");
        IERC20(token).approve(msg.sender, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// A borrower whose behaviour each test sets: approve or not, what to return, what to try mid-loan.
/// It records everything it sees during the callback.
contract ConfigurableBorrower is IERC3156FlashBorrower {
    SimplePool internal pool;
    bool public doApprove = true;
    bytes32 public answer = keccak256("ERC3156FlashBorrower.onFlashLoan");
    bytes public reenterCall;

    address public seenInitiator;
    address public seenToken;
    uint256 public seenAmount;
    uint256 public seenFee;
    bytes public seenData;
    uint256 public balanceDuring;
    uint256 public reserve0During;
    uint256 public reserve1During;
    bytes public reenterError;

    constructor(SimplePool pool_) {
        pool = pool_;
    }

    function configure(bool approve_, bytes32 answer_, bytes calldata reenterCall_) external {
        doApprove = approve_;
        answer = answer_;
        reenterCall = reenterCall_;
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        seenInitiator = initiator;
        seenToken = token;
        seenAmount = amount;
        seenFee = fee;
        seenData = data;
        balanceDuring = IERC20(token).balanceOf(address(this));
        reserve0During = pool.reserve0();
        reserve1During = pool.reserve1();
        if (reenterCall.length > 0) {
            (bool ok, bytes memory err) = address(pool).call(reenterCall);
            require(!ok, "reentry succeeded");
            reenterError = err;
        }
        if (doApprove) IERC20(token).approve(msg.sender, amount + fee);
        return answer;
    }
}

/// Answers every unknown call with 32 bytes (the number 1), like some older wallet designs.
contract AnswersEverything {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

/// Accepts every call and returns nothing.
contract EmptyFallback {
    fallback() external {}
}

// ====================================================================== the tests

contract SimplePoolFlashLoanTest is Test {
    MockERC20 internal weth;
    MockERC20 internal usdc;
    SimplePool internal pool;
    ConfigurableBorrower internal borrower;

    address internal alice = makeAddr("alice"); // the liquidity provider
    address internal bob = makeAddr("bob"); // calls flashLoan
    address internal dave = makeAddr("dave"); // the liquidator

    bytes32 internal constant OK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    event FlashLoan(
        address indexed initiator, address indexed receiver, address indexed token, uint256 amount, uint256 fee
    );

    function setUp() public {
        vm.warp(1_700_000_000);
        weth = new MockERC20(18);
        usdc = new MockERC20(6);
        pool = new SimplePool(IERC20(address(weth)), IERC20(address(usdc)), "Simple LP", "SLP");
        weth.mint(alice, 1e30);
        usdc.mint(alice, 1e30);
        vm.startPrank(alice);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.addLiquidity(100e18, 200_000e6, 0); // price 2,000 USDC per ETH
        vm.stopPrank();

        borrower = new ConfigurableBorrower(pool);
        usdc.mint(address(borrower), 1_000_000e6); // enough to pay any fee
        weth.mint(address(borrower), 1_000e18);
    }

    function _loan(address token, uint256 amount) internal returns (bool) {
        vm.prank(bob);
        return pool.flashLoan(borrower, token, amount, "");
    }

    // ------------------------------------------------------------------ the liquidation story

    function _liquidationSetup(uint256 dexPrice) internal returns (Liquidator liq, MockLendy lendy) {
        lendy = new MockLendy(usdc, weth);
        MockDexB dex = new MockDexB(usdc, weth, dexPrice);
        weth.mint(address(lendy), 5.25e18);
        usdc.mint(address(dex), 1_000_000e6);
        liq = new Liquidator(pool, lendy, dex, usdc, weth);
    }

    function test_Liquidation_DaveEarns438_50_WithZeroCapital() public {
        (Liquidator liq,) = _liquidationSetup(2_000e6);
        assertEq(usdc.balanceOf(address(liq)), 0);
        uint256 reserveBefore = pool.reserve1();

        vm.prank(dave);
        liq.go();

        // 5.25 ETH x 2,000 = 10,500; x 0.997 = 10,468.50; minus 10,000 + 30 owed = 438.50
        assertEq(usdc.balanceOf(address(liq)), 438_500_000);
        assertEq(pool.reserve1(), reserveBefore + 30e6); // the LPs earned the 30 USDC fee
        assertEq(pool.reserve1(), usdc.balanceOf(address(pool)));
    }

    function test_Liquidation_Unprofitable_RevertsAndNothingChanges() public {
        (Liquidator liq, MockLendy lendy) = _liquidationSetup(1_900e6);
        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();

        // 5.25 ETH x 1,900 x 0.997 = 9,945.075 USDC: less than the 10,030 owed
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(liq), 9_945_075_000, 10_030e6
            )
        );
        liq.go();

        assertEq(pool.reserve0(), r0);
        assertEq(pool.reserve1(), r1);
        assertEq(weth.balanceOf(address(lendy)), 5.25e18); // the liquidation was undone too
    }

    // ------------------------------------------------------------------ ERC-3156: the view functions

    function test_MaxFlashLoan_IsTheReserve_AndZeroForOtherTokens() public view {
        assertEq(pool.maxFlashLoan(address(weth)), 100e18);
        assertEq(pool.maxFlashLoan(address(usdc)), 200_000e6);
        assertEq(pool.maxFlashLoan(address(0xBEEF)), 0); // the standard says 0, not a revert
    }

    function test_FlashFee_Is0_3Percent_RoundedUp() public view {
        assertEq(pool.flashFee(address(usdc), 10_000e6), 30e6);
        assertEq(pool.flashFee(address(weth), 1e18), 0.003e18);
        assertEq(pool.flashFee(address(usdc), 1), 1); // 0.0003 rounds up: tiny loans are not free
        assertEq(pool.flashFee(address(usdc), 3_333), 10); // 9.999 rounds up to 10
        assertEq(pool.flashFee(address(usdc), 0), 0);
    }

    function test_RevertWhen_FlashFeeForAnotherToken() public {
        vm.expectRevert(abi.encodeWithSelector(SimplePool.Pool__InvalidToken.selector, address(0xBEEF)));
        pool.flashFee(address(0xBEEF), 1);
    }

    // ------------------------------------------------------------------ ERC-3156: flashLoan

    function test_FlashLoan_ReturnsTrue_AndPassesEverythingOnUnchanged() public {
        vm.prank(bob);
        bool ok = pool.flashLoan(borrower, address(usdc), 1_000e6, hex"c0ffee");

        assertTrue(ok);
        assertEq(borrower.seenInitiator(), bob); // msg.sender, not the pool (review bug)
        assertEq(borrower.seenToken(), address(usdc));
        assertEq(borrower.seenAmount(), 1_000e6);
        assertEq(borrower.seenFee(), pool.flashFee(address(usdc), 1_000e6));
        assertEq(borrower.seenData(), hex"c0ffee");
        assertEq(borrower.balanceDuring(), 1_000_000e6 + 1_000e6); // the tokens arrived before the callback
    }

    function test_FlashLoan_EmitsWithTheRightAddresses() public {
        vm.expectEmit(true, true, true, true, address(pool));
        emit FlashLoan(bob, address(borrower), address(usdc), 1_000e6, 3e6); // review bug: order was wrong
        _loan(address(usdc), 1_000e6);
    }

    function test_FlashLoan_FeeGoesToTheReserve_LpsEarnIt() public {
        uint256 shares = pool.balanceOf(alice);
        uint256 r1 = pool.reserve1();
        _loan(address(usdc), 100_000e6);
        assertEq(pool.reserve1(), r1 + 300e6);
        assertEq(pool.reserve1(), usdc.balanceOf(address(pool)));
        assertEq(pool.reserve0(), weth.balanceOf(address(pool)));

        vm.prank(alice);
        (, uint256 a1) = pool.removeLiquidity(shares, 0, 0);
        assertGt(a1, 200_000e6 - 1e6); // she gets the fee (minus the tiny locked part)
    }

    function test_FlashLoan_BothTokens() public {
        _loan(address(weth), 10e18);
        assertEq(pool.reserve0(), 100e18 + 0.03e18);
        _loan(address(usdc), 10_000e6);
        assertEq(pool.reserve1(), 200_000e6 + 30e6);
    }

    function test_FlashLoan_TheWholeReserve() public {
        _loan(address(usdc), 200_000e6);
        assertEq(pool.reserve1(), 200_600e6);
    }

    function test_FlashLoan_StandardBorrowerFromTheSpec_Works() public {
        StandardBorrower std = new StandardBorrower(pool);
        usdc.mint(address(std), 10e6);
        std.borrow(address(usdc), 1_000e6); // review bug: this used to revert "Untrusted loan initiator"
        assertEq(usdc.balanceOf(address(std)), 7e6);
    }

    function test_RevertWhen_FlashLoanZero() public {
        vm.prank(bob);
        vm.expectRevert(SimplePool.Pool__ZeroAmount.selector);
        pool.flashLoan(borrower, address(usdc), 0, "");
    }

    function test_RevertWhen_FlashLoanAnotherToken() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SimplePool.Pool__InvalidToken.selector, address(0xBEEF)));
        pool.flashLoan(borrower, address(0xBEEF), 1, "");
    }

    function test_RevertWhen_FlashLoanAboveTheReserve() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SimplePool.Pool__FlashLoanTooLarge.selector, 200_000e6 + 1, 200_000e6));
        pool.flashLoan(borrower, address(usdc), 200_000e6 + 1, "");
    }

    function test_RevertWhen_BorrowerDoesNotApproveTheRepayment() public {
        borrower.configure(false, OK, "");
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, 1_003e6)
        );
        pool.flashLoan(borrower, address(usdc), 1_000e6, "");
    }

    function test_RevertWhen_BorrowerCannotPay() public {
        ConfigurableBorrower broke = new ConfigurableBorrower(pool); // holds nothing, cannot pay the fee
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(broke), 1_000e6, 1_003e6)
        );
        pool.flashLoan(broke, address(usdc), 1_000e6, "");
    }

    function test_RevertWhen_BorrowerReturnsTheWrongValue() public {
        borrower.configure(true, bytes32(uint256(1)), "");
        vm.prank(bob);
        vm.expectRevert(SimplePool.Pool__CallbackFailed.selector);
        pool.flashLoan(borrower, address(usdc), 1_000e6, "");
    }

    // ------------------------------------------------------------------ people who never asked for a loan

    function test_Victim_ContractThatAnswersEverything_CannotBeMadeToPayFees() public {
        AnswersEverything v = new AnswersEverything();
        usdc.mint(address(v), 100_000e6);
        vm.prank(address(v));
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(SimplePool.Pool__CallbackFailed.selector); // without the check it would lose 300 USDC
        pool.flashLoan(IERC3156FlashBorrower(address(v)), address(usdc), 100_000e6, "");
        assertEq(usdc.balanceOf(address(v)), 100_000e6);
    }

    function test_Victim_ContractWithAnEmptyFallback() public {
        EmptyFallback v = new EmptyFallback();
        usdc.mint(address(v), 100_000e6);
        vm.prank(address(v));
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(); // no 32-byte answer: the call itself fails to decode
        pool.flashLoan(IERC3156FlashBorrower(address(v)), address(usdc), 1_000e6, "");
        assertEq(usdc.balanceOf(address(v)), 100_000e6);
    }

    function test_Victim_WalletThatApprovedThePool() public {
        // alice approved the pool for everything when she added liquidity
        uint256 before = usdc.balanceOf(alice);
        vm.prank(bob);
        vm.expectRevert(); // a wallet has no code to call
        pool.flashLoan(IERC3156FlashBorrower(alice), address(usdc), 1_000e6, "");
        assertEq(usdc.balanceOf(alice), before);
    }

    // ------------------------------------------------------------------ during the loan

    function test_DuringTheLoan_ReservesAndPriceDoNotChange() public {
        _loan(address(usdc), 50_000e6);
        assertEq(borrower.reserve0During(), 100e18);
        assertEq(borrower.reserve1During(), 200_000e6); // what LPs own; the loan is owed back
    }

    function _assertBlocked() internal view {
        assertEq(borrower.reenterError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function test_DuringTheLoan_SwapIsBlocked() public {
        borrower.configure(true, OK, abi.encodeCall(SimplePool.swap, (address(weth), 1e18, 0, block.timestamp)));
        _loan(address(usdc), 50_000e6);
        _assertBlocked();
    }

    function test_DuringTheLoan_AddIsBlocked() public {
        borrower.configure(true, OK, abi.encodeCall(SimplePool.addLiquidity, (1e18, 2_000e6, 0)));
        _loan(address(usdc), 50_000e6);
        _assertBlocked();
    }

    function test_DuringTheLoan_RemoveIsBlocked() public {
        borrower.configure(true, OK, abi.encodeCall(SimplePool.removeLiquidity, (1, 0, 0)));
        _loan(address(usdc), 50_000e6);
        _assertBlocked();
    }

    function test_DuringTheLoan_AnotherFlashLoanIsBlocked() public {
        borrower.configure(true, OK, abi.encodeCall(SimplePool.flashLoan, (borrower, address(weth), 1e18, "")));
        _loan(address(usdc), 50_000e6);
        _assertBlocked();
    }

    // ------------------------------------------------------------------ links to v2

    function test_FlashLoan_RecordsTheTimeAtTheOldPriceFirst() public {
        uint256 p0 = uint256(200_000e6) * 2 ** 112 / 100e18;
        vm.warp(block.timestamp + 100);
        _loan(address(usdc), 10_000e6); // the fee nudges the price afterwards
        assertEq(pool.price0CumulativeLast(), p0 * 100);
        assertEq(pool.blockTimestampLast(), block.timestamp);
    }

    function test_RevertWhen_TheFeeWouldPushAReserveAbove2Pow112() public {
        MockERC20 a = new MockERC20(18);
        MockERC20 b = new MockERC20(18);
        SimplePool p = new SimplePool(IERC20(address(a)), IERC20(address(b)), "LP", "LP");
        a.mint(address(this), type(uint128).max);
        b.mint(address(this), type(uint128).max);
        a.approve(address(p), type(uint256).max);
        b.approve(address(p), type(uint256).max);
        p.addLiquidity(type(uint112).max, 1e18, 0); // reserve0 exactly at the cap

        ConfigurableBorrower big = new ConfigurableBorrower(p);
        a.mint(address(big), 1e30);
        vm.expectRevert(SimplePool.Pool__ReserveOverflow.selector);
        p.flashLoan(big, address(a), 1e30, "");
    }
}
