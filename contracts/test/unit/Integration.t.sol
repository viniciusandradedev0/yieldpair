// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Factory } from "../../src/amm/Factory.sol";
import { Pair } from "../../src/amm/Pair.sol";
import { IPair } from "../../src/interfaces/IPair.sol";
import { TestToken } from "../../src/tokens/TestToken.sol";
import { MockLendingPool } from "../mocks/MockLendingPool.sol";

/// @title IntegrationTest
/// @notice Unit tests for the Pair ↔ LendingPool integration:
///         sweep-on-mint, recall-on-swap/burn, graceful failure when frozen,
///         pool switching, and the totalReserve = physical + supplied invariant.
///
/// @dev setUp deploys a fresh Factory, two TestTokens, one Pair, and one
///      MockLendingPool for every test. The test contract itself is the Factory
///      owner and therefore can call `factory.setPairLendingPool` directly.
///
///      Event checking strategy: because `mint` and `swap` emit ERC20 Transfer
///      events before the Pair's Sweep/Recall events, using vm.expectEmit would
///      mismatch on the first unmatched Transfer. We use `vm.recordLogs` +
///      `_findLog` helpers to assert event existence without order dependency.
contract IntegrationTest is Test {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant MINIMUM_LIQUIDITY = 1000;
    address internal constant DEAD = address(0xdEaD);

    // -------------------------------------------------------------------------
    // Event selectors (computed once)
    // -------------------------------------------------------------------------

    bytes32 internal constant SWEEP_SIG = keccak256("Sweep(address,uint256)");
    bytes32 internal constant RECALL_SIG = keccak256("Recall(address,uint256)");

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    Factory internal factory;
    Pair internal pair;
    MockLendingPool internal mockLP;

    TestToken internal token0;
    TestToken internal token1;

    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        factory = new Factory();
        // address(this) is the deployer — it is the Factory owner.

        TestToken tokenA = new TestToken("Token A", "TKA", 0);
        TestToken tokenB = new TestToken("Token B", "TKB", 0);

        address pairAddr = factory.createPair(address(tokenA), address(tokenB));
        pair = Pair(pairAddr);

        // Use the pair's sorted token0/token1 throughout the tests.
        token0 = TestToken(pair.token0());
        token1 = TestToken(pair.token1());

        mockLP = new MockLendingPool();

        // Fund actors with a generous supply.
        token0.mint(lp, 10_000_000 ether);
        token1.mint(lp, 10_000_000 ether);
        token0.mint(trader, 10_000_000 ether);
        token1.mint(trader, 10_000_000 ether);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Transfer token0/token1 to the pair then call mint, returns LP minted.
    function _addLiquidity(address from, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 lpMinted)
    {
        vm.startPrank(from);
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
        vm.stopPrank();
        lpMinted = pair.mint(from);
    }

    /// @dev Transfer LP tokens to the pair then call burn, returns (amount0, amount1).
    function _burnLiquidity(address from, uint256 lpAmount)
        internal
        returns (uint256 a0, uint256 a1)
    {
        vm.prank(from);
        pair.transfer(address(pair), lpAmount);
        (a0, a1) = pair.burn(from);
    }

    /// @dev Assert the core invariant: getReserves == physical + supplied.
    function _assertTotalReserveInvariant(string memory label) internal view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint112 s0, uint112 s1) = pair.suppliedReserves();
        uint256 phys0 = token0.balanceOf(address(pair));
        uint256 phys1 = token1.balanceOf(address(pair));
        assertEq(r0, phys0 + s0, string.concat(label, ": reserve0 == phys0 + s0"));
        assertEq(r1, phys1 + s1, string.concat(label, ": reserve1 == phys1 + s1"));
    }

    /// @dev Returns true if the recorded logs contain at least one event whose
    ///      first topic (selector) matches `selector` and whose first indexed topic
    ///      (topic[1]) matches `tokenAddr` (for Sweep/Recall which have `token` indexed).
    function _hasLog(Vm.Log[] memory logs, bytes32 selector, address tokenAddr)
        internal
        pure
        returns (bool)
    {
        bytes32 addrTopic = bytes32(uint256(uint160(tokenAddr)));
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].topics.length >= 2 && logs[i].topics[0] == selector
                    && logs[i].topics[1] == addrTopic
            ) {
                return true;
            }
        }
        return false;
    }

    // =========================================================================
    // (a) Sweep on mint
    // =========================================================================

    /// @notice After mint with a 20% buffer, `suppliedReserves` > 0 and
    ///         `getReserves()` still returns the full total.
    function test_sweep_afterMint_suppliesExcessToLending() public {
        uint16 bufBps = 2000; // 20% buffer
        factory.setPairLendingPool(address(pair), address(mockLP), bufBps);

        vm.recordLogs();
        _addLiquidity(lp, 100 ether, 100 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Both tokens must have been swept.
        assertTrue(_hasLog(logs, SWEEP_SIG, address(token0)), "Sweep event for token0 not emitted");
        assertTrue(_hasLog(logs, SWEEP_SIG, address(token1)), "Sweep event for token1 not emitted");

        (uint112 s0, uint112 s1) = pair.suppliedReserves();
        assertGt(s0, 0, "s0 should be > 0: excess swept to lending");
        assertGt(s1, 0, "s1 should be > 0: excess swept to lending");

        // getReserves must equal physical + supplied.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 phys0 = token0.balanceOf(address(pair));
        uint256 phys1 = token1.balanceOf(address(pair));
        assertEq(r0, phys0 + s0, "reserve0 == physical0 + supplied0");
        assertEq(r1, phys1 + s1, "reserve1 == physical1 + supplied1");

        // Physical balance should be exactly targetLiquid.
        uint256 targetLiquid0 = (uint256(r0) * bufBps + 9999) / 10_000;
        uint256 targetLiquid1 = (uint256(r1) * bufBps + 9999) / 10_000;
        assertEq(phys0, targetLiquid0, "physical0 == targetLiquid0 (after sweep)");
        assertEq(phys1, targetLiquid1, "physical1 == targetLiquid1 (after sweep)");

        // MockLP must have received the principal.
        assertEq(mockLP.deposited(address(token0)), s0, "mockLP deposited token0");
        assertEq(mockLP.deposited(address(token1)), s1, "mockLP deposited token1");
    }

    // =========================================================================
    // (b) No sweep when buffer == 100%
    // =========================================================================

    /// @notice With a 100% buffer (nothing swept), suppliedReserves must be (0, 0).
    function test_sweep_doesNotSupplyBelowBuffer() public {
        uint16 bufBps = 10_000; // 100% buffer — nothing is swept
        factory.setPairLendingPool(address(pair), address(mockLP), bufBps);

        _addLiquidity(lp, 100 ether, 100 ether);

        (uint112 s0, uint112 s1) = pair.suppliedReserves();
        assertEq(s0, 0, "s0 should be 0: buffer covers everything");
        assertEq(s1, 0, "s1 should be 0: buffer covers everything");
    }

    // =========================================================================
    // (c) Swap triggers recall from lending
    // =========================================================================

    /// @notice A swap that needs more than the physical buffer recalls from lending
    ///         and completes successfully. The totalReserve invariant holds.
    function test_swap_recallsFromLendingWhenNeeded() public {
        uint16 bufBps = 1000; // 10% buffer — 90% goes to lending
        factory.setPairLendingPool(address(pair), address(mockLP), bufBps);

        _addLiquidity(lp, 100 ether, 100 ether);

        // Physical token1 balance after mint with 10% buffer ≈ 10 ether.
        uint256 physToken1 = token1.balanceOf(address(pair));

        // Compute a swap output that clearly exceeds physToken1.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 largeIn = 20 ether;
        uint256 amountInWithFee = largeIn * 997;
        uint256 amountOut = (amountInWithFee * r1) / (uint256(r0) * 1000 + amountInWithFee);

        assertTrue(
            amountOut > physToken1,
            "test setup: amountOut must exceed physical balance to trigger recall"
        );

        // Record logs and execute the swap.
        vm.recordLogs();
        vm.startPrank(trader);
        token0.transfer(address(pair), largeIn);
        vm.stopPrank();
        pair.swap(0, amountOut, trader, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Recall event must have been emitted for token1.
        assertTrue(
            _hasLog(logs, RECALL_SIG, address(token1)), "Recall event for token1 not emitted"
        );

        // trader received the tokens.
        assertEq(token1.balanceOf(trader), 10_000_000 ether + amountOut, "trader received token1");

        // Invariant: getReserves == physical + supplied.
        _assertTotalReserveInvariant("post-swap");
    }

    // =========================================================================
    // (d) Swap reverts gracefully when lending is frozen
    // =========================================================================

    /// @notice When the lending pool is frozen, a swap requiring recall reverts
    ///         with InsufficientLiquidity. A smaller swap (within physical) still works.
    function test_swap_revertsGraciouslyWhenLendingFrozen() public {
        uint16 bufBps = 1000; // 10% buffer
        factory.setPairLendingPool(address(pair), address(mockLP), bufBps);

        _addLiquidity(lp, 100 ether, 100 ether);

        mockLP.freeze();

        // Large swap — needs recall — must revert.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 largeIn = 20 ether;
        uint256 amountInWithFee = largeIn * 997;
        uint256 largeOut = (amountInWithFee * r1) / (uint256(r0) * 1000 + amountInWithFee);

        uint256 physToken1 = token1.balanceOf(address(pair));
        assertTrue(largeOut > physToken1, "setup: largeOut must exceed physical balance");

        vm.startPrank(trader);
        token0.transfer(address(pair), largeIn);
        vm.expectRevert(IPair.InsufficientLiquidity.selector);
        pair.swap(0, largeOut, trader, "");
        vm.stopPrank();

        // A smaller swap that fits within the physical balance must still succeed.
        (r0, r1,) = pair.getReserves();
        uint256 smallIn = 1 ether;
        amountInWithFee = smallIn * 997;
        uint256 smallOut = (amountInWithFee * r1) / (uint256(r0) * 1000 + amountInWithFee);

        physToken1 = token1.balanceOf(address(pair));
        assertTrue(smallOut <= physToken1, "setup: smallOut must fit within physical balance");

        vm.startPrank(trader);
        token0.transfer(address(pair), smallIn);
        vm.stopPrank();
        pair.swap(0, smallOut, trader, "");

        assertEq(
            token1.balanceOf(trader),
            10_000_000 ether + smallOut,
            "trader received token1 on small swap"
        );
    }

    // =========================================================================
    // (e) Burn triggers recall from lending
    // =========================================================================

    /// @notice Burning LP tokens when most liquidity sits in lending recalls the
    ///         necessary amount and delivers tokens to the burner.
    function test_burn_recallsFromLendingWhenNeeded() public {
        uint16 bufBps = 1000; // 10% buffer
        factory.setPairLendingPool(address(pair), address(mockLP), bufBps);

        uint256 lpMinted = _addLiquidity(lp, 100 ether, 100 ether);

        uint256 burnAmt = lpMinted / 2;

        uint256 balBefore0 = token0.balanceOf(lp);
        uint256 balBefore1 = token1.balanceOf(lp);

        vm.recordLogs();
        (uint256 a0, uint256 a1) = _burnLiquidity(lp, burnAmt);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Recall events must appear for both tokens.
        assertTrue(
            _hasLog(logs, RECALL_SIG, address(token0)), "Recall event for token0 not emitted"
        );
        assertTrue(
            _hasLog(logs, RECALL_SIG, address(token1)), "Recall event for token1 not emitted"
        );

        assertGt(a0, 0, "burn: received token0");
        assertGt(a1, 0, "burn: received token1");
        assertEq(token0.balanceOf(lp), balBefore0 + a0, "lp received token0");
        assertEq(token1.balanceOf(lp), balBefore1 + a1, "lp received token1");
    }

    // =========================================================================
    // (f) Burn reverts when lending frozen
    // =========================================================================

    /// @notice Burning LP tokens when the lending pool is frozen and physical balance
    ///         is insufficient reverts with LendingWithdrawFailed.
    function test_burn_revertsWhenLendingFrozen() public {
        uint16 bufBps = 1000; // 10% buffer
        factory.setPairLendingPool(address(pair), address(mockLP), bufBps);

        uint256 lpMinted = _addLiquidity(lp, 100 ether, 100 ether);

        mockLP.freeze();

        uint256 burnAmt = lpMinted / 2;
        vm.prank(lp);
        pair.transfer(address(pair), burnAmt);

        vm.expectRevert(IPair.LendingWithdrawFailed.selector);
        pair.burn(lp);
    }

    // =========================================================================
    // (g) setLendingPool drains supplied before switching
    // =========================================================================

    /// @notice Switching the lending pool recalls all supplied tokens first, so
    ///         suppliedReserves == (0, 0) after the switch, and the pair stays functional.
    function test_setLendingPool_recallsAllBeforeSwitching() public {
        uint16 bufBps = 2000; // 20% buffer
        factory.setPairLendingPool(address(pair), address(mockLP), bufBps);

        _addLiquidity(lp, 100 ether, 100 ether);

        (uint112 s0Before, uint112 s1Before) = pair.suppliedReserves();
        assertGt(s0Before, 0, "some token0 was supplied before switch");
        assertGt(s1Before, 0, "some token1 was supplied before switch");

        // Deploy a second mock to switch to.
        MockLendingPool mockLP2 = new MockLendingPool();

        // Switch to the new pool — old pool must be drained first.
        factory.setPairLendingPool(address(pair), address(mockLP2), bufBps);

        (uint112 s0After, uint112 s1After) = pair.suppliedReserves();
        assertEq(s0After, 0, "suppliedReserves.s0 should be 0 after recall");
        assertEq(s1After, 0, "suppliedReserves.s1 should be 0 after recall");

        // Old mock should have nothing left.
        assertEq(mockLP.deposited(address(token0)), 0, "old mockLP: token0 fully recalled");
        assertEq(mockLP.deposited(address(token1)), 0, "old mockLP: token1 fully recalled");

        // The pair must be functional: a swap should work.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 swapIn = 1 ether;
        uint256 amountInWithFee = swapIn * 997;
        uint256 swapOut = (amountInWithFee * r1) / (uint256(r0) * 1000 + amountInWithFee);

        vm.startPrank(trader);
        token0.transfer(address(pair), swapIn);
        vm.stopPrank();
        pair.swap(0, swapOut, trader, "");

        assertEq(
            token1.balanceOf(trader), 10_000_000 ether + swapOut, "trader swap after pool switch"
        );
    }

    // =========================================================================
    // (h) setLendingPool reverts with CannotRecall when frozen
    // =========================================================================

    /// @notice Calling `setPairLendingPool` when the current lending pool is frozen
    ///         reverts with CannotRecall.
    function test_setLendingPool_revertsWithCannotRecall_whenFrozen() public {
        uint16 bufBps = 2000;
        factory.setPairLendingPool(address(pair), address(mockLP), bufBps);

        _addLiquidity(lp, 100 ether, 100 ether);

        mockLP.freeze();

        vm.expectRevert(IPair.CannotRecall.selector);
        factory.setPairLendingPool(address(pair), address(0), 0);
    }

    // =========================================================================
    // (i) getReserves == physical + supplied invariant
    // =========================================================================

    /// @notice After every operation, getReserves() == balanceOf(pair) + suppliedReserves().
    function test_getReserves_equalsTotalPhysicalPlusSupplied() public {
        uint16 bufBps = 3000; // 30% buffer
        factory.setPairLendingPool(address(pair), address(mockLP), bufBps);

        // After mint.
        _addLiquidity(lp, 50 ether, 50 ether);
        _assertTotalReserveInvariant("after first mint");

        // After a second mint.
        _addLiquidity(lp, 10 ether, 10 ether);
        _assertTotalReserveInvariant("after second mint");

        // After swap.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 swapIn = 2 ether;
        uint256 amountInWithFee = swapIn * 997;
        uint256 swapOut = (amountInWithFee * r1) / (uint256(r0) * 1000 + amountInWithFee);
        vm.startPrank(trader);
        token0.transfer(address(pair), swapIn);
        vm.stopPrank();
        pair.swap(0, swapOut, trader, "");
        _assertTotalReserveInvariant("after swap");
    }

    // =========================================================================
    // (j) Disable lending (set to address(0))
    // =========================================================================

    /// @notice Setting the lending pool to address(0) returns the pair to pure-AMM mode.
    ///         The pair continues to operate normally.
    function test_disableLending_setToAddressZero() public {
        uint16 bufBps = 2000;
        factory.setPairLendingPool(address(pair), address(mockLP), bufBps);

        _addLiquidity(lp, 100 ether, 100 ether);

        // Switch to address(0) — this triggers _recallAll.
        factory.setPairLendingPool(address(pair), address(0), 0);

        assertEq(pair.lendingPool(), address(0), "lendingPool should be address(0)");
        (uint112 s0, uint112 s1) = pair.suppliedReserves();
        assertEq(s0, 0, "supplied0 == 0 after disabling");
        assertEq(s1, 0, "supplied1 == 0 after disabling");

        // Add more liquidity — no sweep should happen.
        _addLiquidity(lp, 10 ether, 10 ether);
        (uint112 s0b, uint112 s1b) = pair.suppliedReserves();
        assertEq(s0b, 0, "supplied0 == 0 after mint in AMM-only mode");
        assertEq(s1b, 0, "supplied1 == 0 after mint in AMM-only mode");

        // A swap should work normally.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 swapIn = 1 ether;
        uint256 amountInWithFee = swapIn * 997;
        uint256 swapOut = (amountInWithFee * r1) / (uint256(r0) * 1000 + amountInWithFee);
        vm.startPrank(trader);
        token0.transfer(address(pair), swapIn);
        vm.stopPrank();
        pair.swap(0, swapOut, trader, "");

        assertEq(
            token1.balanceOf(trader), 10_000_000 ether + swapOut, "swap works in AMM-only mode"
        );
    }

    // =========================================================================
    // (k) supplied_i <= totalReserve_i always
    // =========================================================================

    /// @notice supplied_i can never exceed the total reserve of that token.
    function test_supplied_neverExceedsTotalReserve() public {
        uint16 bufBps = 1000; // 10% buffer — most goes to lending
        factory.setPairLendingPool(address(pair), address(mockLP), bufBps);

        _addLiquidity(lp, 100 ether, 100 ether);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint112 s0, uint112 s1) = pair.suppliedReserves();

        assertLe(s0, r0, "supplied0 <= totalReserve0");
        assertLe(s1, r1, "supplied1 <= totalReserve1");
    }

    // =========================================================================
    // (l) Sweep event amount is correct
    // =========================================================================

    /// @notice The Sweep event carries the correct amount (totalBalance - targetLiquid).
    function test_sweep_eventAmount_isCorrect() public {
        uint16 bufBps = 2000; // 20% buffer
        factory.setPairLendingPool(address(pair), address(mockLP), bufBps);

        uint256 amt = 100 ether;
        // For the first mint, both total reserves will equal `amt`.
        // targetLiquid = ceil(amt * 2000 / 10000) = 20 ether (exact, no rounding needed).
        // excess = 100 ether - 20 ether = 80 ether.
        uint256 expectedExcess = amt - (amt * bufBps + 9999) / 10_000;

        vm.recordLogs();
        _addLiquidity(lp, amt, amt);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find and decode the Sweep event for each token.
        uint256 sweepCount;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == SWEEP_SIG) {
                uint256 sweepAmount = abi.decode(logs[i].data, (uint256));
                assertEq(sweepAmount, expectedExcess, "Sweep amount mismatch");
                sweepCount++;
            }
        }
        assertEq(sweepCount, 2, "Expected exactly 2 Sweep events (one per token)");
    }
}
