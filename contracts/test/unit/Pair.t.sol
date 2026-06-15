// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Factory } from "../../src/amm/Factory.sol";
import { Pair } from "../../src/amm/Pair.sol";
import { IPair } from "../../src/interfaces/IPair.sol";
import { TestToken } from "../../src/tokens/TestToken.sol";

/// @title PairTest
/// @notice Unit tests for `Pair`: mint/burn/swap accounting, fee application, the
///         constant-product (k) invariant, and revert paths.
contract PairTest is Test {
    Factory internal factory;
    TestToken internal tokenA;
    TestToken internal tokenB;
    Pair internal pair;

    address internal token0;
    address internal token1;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant MINIMUM_LIQUIDITY = 1000;

    /// @dev Mirrors `Pair.DEAD` — the address `MINIMUM_LIQUIDITY` LP shares are
    ///      permanently locked to on the first mint (OZ v5 `_mint` reverts on
    ///      `address(0)`, so a dead address is used instead).
    address internal constant DEAD = address(0xdEaD);

    function setUp() public {
        factory = new Factory();
        tokenA = new TestToken("Token A", "TKA", 0);
        tokenB = new TestToken("Token B", "TKB", 0);

        address pairAddr = factory.createPair(address(tokenA), address(tokenB));
        pair = Pair(pairAddr);

        token0 = pair.token0();
        token1 = pair.token1();

        // Mint a generous supply to both users for every test.
        tokenA.mint(alice, 1_000_000 ether);
        tokenB.mint(alice, 1_000_000 ether);
        tokenA.mint(bob, 1_000_000 ether);
        tokenB.mint(bob, 1_000_000 ether);
    }

    /// @dev Helper: transfers `amount0`/`amount1` of token0/token1 to the pair, then
    ///      calls `mint(to)`.
    function _addLiquidity(address from, uint256 amount0, uint256 amount1, address to)
        internal
        returns (uint256 liquidity)
    {
        vm.startPrank(from);
        bool ok0 = _erc20(token0).transfer(address(pair), amount0);
        bool ok1 = _erc20(token1).transfer(address(pair), amount1);
        vm.stopPrank();
        require(ok0 && ok1, "transfer failed");
        liquidity = pair.mint(to);
    }

    function _erc20(address token) internal pure returns (TestToken) {
        return TestToken(token);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // mint
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice First mint locks MINIMUM_LIQUIDITY to address(0) and credits the
    ///         depositor with sqrt(amount0*amount1) - MINIMUM_LIQUIDITY.
    function test_mint_first_locksMinimumLiquidity() public {
        uint256 amount0 = 4 ether;
        uint256 amount1 = 100 ether;
        uint256 expectedLiquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;

        uint256 liquidity = _addLiquidity(alice, amount0, amount1, alice);

        assertEq(
            liquidity, expectedLiquidity, "alice should receive sqrt(a0*a1) - MINIMUM_LIQUIDITY"
        );
        assertEq(pair.balanceOf(alice), expectedLiquidity, "alice LP balance");
        assertEq(
            pair.balanceOf(DEAD), MINIMUM_LIQUIDITY, "DEAD LP balance (locked MINIMUM_LIQUIDITY)"
        );
        assertEq(
            pair.totalSupply(),
            expectedLiquidity + MINIMUM_LIQUIDITY,
            "totalSupply == minted + locked MINIMUM_LIQUIDITY"
        );

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, amount0, "reserve0 after first mint");
        assertEq(r1, amount1, "reserve1 after first mint");
    }

    /// @notice Emits Mint with the raw transferred amounts (not the liquidity minted).
    function test_mint_first_emitsMintEvent() public {
        uint256 amount0 = 4 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(alice);
        _erc20(token0).transfer(address(pair), amount0);
        _erc20(token1).transfer(address(pair), amount1);

        vm.expectEmit(true, false, false, true);
        emit IPair.Mint(alice, amount0, amount1);
        // Sync is emitted by _update before Mint.
        pair.mint(alice);
        vm.stopPrank();
    }

    /// @notice Sync event is emitted with the new reserves on mint.
    function test_mint_first_emitsSyncEvent() public {
        uint256 amount0 = 4 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(alice);
        _erc20(token0).transfer(address(pair), amount0);
        _erc20(token1).transfer(address(pair), amount1);
        vm.stopPrank();

        vm.expectEmit(false, false, false, true);
        emit IPair.Sync(uint112(amount0), uint112(amount1));
        pair.mint(alice);
    }

    /// @notice Subsequent mint receives min(amount0*supply/r0, amount1*supply/r1),
    ///         i.e. proportional to the deposited ratio relative to existing reserves.
    function test_mint_subsequent_proportionalToReserves() public {
        // First deposit establishes a 1:25 ratio (4 : 100).
        _addLiquidity(alice, 4 ether, 100 ether, alice);

        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 totalSupplyBefore = pair.totalSupply();

        // Bob deposits at the exact same ratio: 2 : 50.
        uint256 depositAmount0 = 2 ether;
        uint256 depositAmount1 = 50 ether;

        uint256 expectedLiquidity = Math.min(
            (depositAmount0 * totalSupplyBefore) / r0Before,
            (depositAmount1 * totalSupplyBefore) / r1Before
        );

        uint256 liquidity = _addLiquidity(bob, depositAmount0, depositAmount1, bob);

        assertEq(liquidity, expectedLiquidity, "bob's minted liquidity matches min() formula");
        assertEq(pair.balanceOf(bob), expectedLiquidity, "bob LP balance");
        assertEq(
            pair.totalSupply(),
            totalSupplyBefore + expectedLiquidity,
            "totalSupply increases by minted liquidity"
        );
    }

    /// @notice When the deposited ratio is unbalanced, the depositor is credited based
    ///         on the *limiting* token, and the excess of the other token is absorbed
    ///         into reserves (a gift to existing LPs) without reverting.
    function test_mint_subsequent_unbalancedRatio_usesMinAndAbsorbsExcess() public {
        _addLiquidity(alice, 4 ether, 100 ether, alice); // 1 : 25 ratio

        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 totalSupplyBefore = pair.totalSupply();

        // Bob deposits token0 proportionally but WAY more token1 than the ratio calls for.
        uint256 depositAmount0 = 1 ether; // would imply 25 ether of token1 at the ratio
        uint256 depositAmount1 = 1000 ether; // far more than needed

        uint256 liq0 = (depositAmount0 * totalSupplyBefore) / r0Before;
        uint256 liq1 = (depositAmount1 * totalSupplyBefore) / r1Before;
        uint256 expectedLiquidity = Math.min(liq0, liq1);
        assertEq(expectedLiquidity, liq0, "token0 should be the limiting side in this scenario");

        uint256 liquidity = _addLiquidity(bob, depositAmount0, depositAmount1, bob);

        assertEq(liquidity, expectedLiquidity, "bob receives the min() of the two ratios");

        // Reserves now reflect the full balances (excess token1 absorbed).
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertEq(r0After, r0Before + depositAmount0, "reserve0 increases by full deposit");
        assertEq(
            r1After,
            r1Before + depositAmount1,
            "reserve1 increases by full deposit (excess absorbed)"
        );
    }

    /// @notice mint reverts with InsufficientLiquidityMinted if no tokens were
    ///         transferred to the pair beforehand (delta amounts are zero).
    function test_mint_revert_noTransfer() public {
        // First seed the pool so totalSupply != 0 and the zero-delta path is reached
        // via the "else" branch of mint (min(0,0) == 0).
        _addLiquidity(alice, 4 ether, 100 ether, alice);

        // Bob calls mint without transferring anything.
        vm.prank(bob);
        vm.expectRevert(Pair.InsufficientLiquidityMinted.selector);
        pair.mint(bob);
    }

    /// @notice First mint (empty pool) with no transfer reverts due to underflow in
    ///         `sqrt(0*0) - MINIMUM_LIQUIDITY` (sqrt(0) = 0 < MINIMUM_LIQUIDITY).
    function test_mint_revert_firstMint_noTransfer_underflows() public {
        vm.expectRevert();
        pair.mint(alice);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // burn
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice burn returns tokens proportional to the LP share burned, floor-rounded,
    ///         and emits Burn with the actual amounts returned.
    function test_burn_proportionalWithFloorRounding() public {
        uint256 liquidity = _addLiquidity(alice, 4 ether, 100 ether, alice);

        uint256 totalSupplyBefore = pair.totalSupply();
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();

        // Burn half of alice's LP tokens.
        uint256 burnAmount = liquidity / 2;

        uint256 expectedAmount0 = (burnAmount * uint256(r0Before)) / totalSupplyBefore;
        uint256 expectedAmount1 = (burnAmount * uint256(r1Before)) / totalSupplyBefore;
        // Sanity: formula should floor-round (i.e. not be exactly proportional unless divisible).
        assertTrue(expectedAmount0 > 0 && expectedAmount1 > 0, "expected amounts non-zero");

        vm.startPrank(alice);
        pair.transfer(address(pair), burnAmount);

        vm.expectEmit(true, false, false, true);
        emit IPair.Burn(alice, expectedAmount0, expectedAmount1, alice);
        (uint256 amount0, uint256 amount1) = pair.burn(alice);
        vm.stopPrank();

        assertEq(amount0, expectedAmount0, "amount0 == floor(liquidity*balance0/totalSupply)");
        assertEq(amount1, expectedAmount1, "amount1 == floor(liquidity*balance1/totalSupply)");

        assertEq(
            pair.totalSupply(),
            totalSupplyBefore - burnAmount,
            "totalSupply decreases by burned amount"
        );

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertEq(r0After, r0Before - amount0, "reserve0 decreases by amount0");
        assertEq(r1After, r1Before - amount1, "reserve1 decreases by amount1");
    }

    /// @notice burn reverts with InsufficientLiquidityBurned if the LP balance
    ///         transferred to the pair is too small to redeem any tokens (rounds to 0).
    function test_burn_revert_zeroAmounts() public {
        _addLiquidity(alice, 4 ether, 100 ether, alice);

        // Transfer a tiny amount of LP tokens (1 wei) — floor-rounds amount0/amount1 to 0.
        vm.startPrank(alice);
        pair.transfer(address(pair), 1);

        vm.expectRevert(Pair.InsufficientLiquidityBurned.selector);
        pair.burn(alice);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // swap
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A swap respects the constant-product invariant: k after >= k before,
    ///         and the 0.30% fee is correctly applied per AmmLibrary's formula.
    function test_swap_respectsKAndCharges30bpsFee() public {
        _addLiquidity(alice, 10 ether, 10 ether, alice); // balanced pool

        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        uint256 amountIn = 1 ether;

        // amountOut = floor(amountIn * 997 * reserveOut / (reserveIn * 1000 + amountIn * 997))
        uint256 amountInWithFee = amountIn * 997;
        uint256 expectedOut =
            (amountInWithFee * r1Before) / (uint256(r0Before) * 1000 + amountInWithFee);

        // Bob swaps token0 -> token1.
        vm.startPrank(bob);
        _erc20(token0).transfer(address(pair), amountIn);

        vm.expectEmit(true, false, false, true);
        emit IPair.Swap(bob, amountIn, 0, 0, expectedOut, bob);
        pair.swap(0, expectedOut, bob, "");
        vm.stopPrank();

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);

        assertGe(kAfter, kBefore, "k must not decrease after a swap");
        assertGt(kAfter, kBefore, "k strictly increases due to the 0.30% fee");

        assertEq(r0After, r0Before + amountIn, "reserve0 increases by amountIn");
        assertEq(r1After, r1Before - expectedOut, "reserve1 decreases by amountOut");

        assertEq(
            _erc20(token1).balanceOf(bob),
            1_000_000 ether + expectedOut,
            "bob received expectedOut of token1"
        );
    }

    /// @notice swap reverts with InsufficientLiquidity if amountOut >= reserveOut for
    ///         the requested token.
    function test_swap_revert_outputExceedsReserve() public {
        _addLiquidity(alice, 10 ether, 10 ether, alice);

        (uint112 r0,,) = pair.getReserves();

        vm.startPrank(bob);
        _erc20(token0).transfer(address(pair), 1 ether);

        // Requesting exactly reserve1 (>= reserve) must revert.
        (, uint112 r1,) = pair.getReserves();
        vm.expectRevert(Pair.InsufficientLiquidity.selector);
        pair.swap(0, r1, bob, "");
        vm.stopPrank();

        // Sanity: also revert when requesting amount0Out >= reserve0 on the other side.
        vm.startPrank(bob);
        _erc20(token1).transfer(address(pair), 1 ether);
        vm.expectRevert(Pair.InsufficientLiquidity.selector);
        pair.swap(r0, 0, bob, "");
        vm.stopPrank();
    }

    /// @notice swap reverts with InsufficientOutputAmount if both requested outputs are zero.
    function test_swap_revert_bothOutputsZero() public {
        _addLiquidity(alice, 10 ether, 10 ether, alice);

        vm.startPrank(bob);
        _erc20(token0).transfer(address(pair), 1 ether);
        vm.expectRevert(Pair.InsufficientOutputAmount.selector);
        pair.swap(0, 0, bob, "");
        vm.stopPrank();
    }

    /// @notice swap reverts with InsufficientInputAmount if no tokens were sent in
    ///         (caller requests output without funding the swap).
    function test_swap_revert_noInputProvided() public {
        _addLiquidity(alice, 10 ether, 10 ether, alice);

        // Bob requests output without transferring anything in.
        vm.prank(bob);
        vm.expectRevert(Pair.InsufficientInputAmount.selector);
        pair.swap(0, 1 ether, bob, "");
    }

    /// @notice swap reverts with K() if the output requested is too large relative to
    ///         the input provided (would decrease k even after fee).
    function test_swap_revert_kViolation() public {
        _addLiquidity(alice, 10 ether, 10 ether, alice);

        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 amountIn = 1 ether;
        uint256 fairOut = (amountIn * 997 * r1Before) / (uint256(r0Before) * 1000 + amountIn * 997);

        vm.startPrank(bob);
        _erc20(token0).transfer(address(pair), amountIn);
        // Requesting more than the fair amount must revert with K().
        vm.expectRevert(Pair.K.selector);
        pair.swap(0, fairOut + 1, bob, "");
        vm.stopPrank();
    }

    /// @notice swap reverts with InvalidTo if `to` is one of the pair's own tokens.
    function test_swap_revert_invalidTo() public {
        _addLiquidity(alice, 10 ether, 10 ether, alice);

        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 amountIn = 1 ether;
        uint256 fairOut = (amountIn * 997 * r1Before) / (uint256(r0Before) * 1000 + amountIn * 997);

        vm.startPrank(bob);
        _erc20(token0).transfer(address(pair), amountIn);
        vm.expectRevert(Pair.InvalidTo.selector);
        pair.swap(0, fairOut, token1, "");
        vm.stopPrank();
    }
}
