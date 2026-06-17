// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Factory } from "../../src/amm/Factory.sol";
import { Pair } from "../../src/amm/Pair.sol";
import { IPair } from "../../src/interfaces/IPair.sol";
import { TestToken } from "../../src/tokens/TestToken.sol";
import { MockLendingPool } from "../mocks/MockLendingPool.sol";
import { IntegrationHandler } from "./handlers/IntegrationHandler.sol";

/// @title IntegrationInvariantTest
/// @notice Invariant suite for Pair ↔ LendingPool integration.
///
/// Invariants checked:
///   1. totalReserve_i == physical_i + supplied_i  (accounting identity)
///   2. supplied_i <= totalReserve_i               (supplied never exceeds total)
///
/// @dev Uses `IntegrationHandler` as the single target contract.
///      The pool is seeded in `setUp` so reserve-based assertions are exercisable
///      from the very first run.
contract IntegrationInvariantTest is StdInvariant, Test {
    // -------------------------------------------------------------------------
    // Fixture
    // -------------------------------------------------------------------------

    Factory internal factory;
    Pair internal pair;
    MockLendingPool internal mockLP;
    TestToken internal token0;
    TestToken internal token1;

    IntegrationHandler internal handler;

    address internal lp = makeAddr("lp");

    uint256 internal constant SEED_AMOUNT = 1000 ether;
    uint256 internal constant ACTOR_SUPPLY = 1_000_000_000 ether;

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        factory = new Factory();
        // address(this) is the test contract — it is the Factory owner.

        TestToken tokenA = new TestToken("Token A", "TKA", 0);
        TestToken tokenB = new TestToken("Token B", "TKB", 0);

        address pairAddr = factory.createPair(address(tokenA), address(tokenB));
        pair = Pair(pairAddr);

        token0 = TestToken(pair.token0());
        token1 = TestToken(pair.token1());

        mockLP = new MockLendingPool();

        // Configure a 20% buffer.
        factory.setPairLendingPool(address(pair), address(mockLP), 2000);

        // Fund the lp actor with abundant tokens.
        token0.mint(lp, ACTOR_SUPPLY);
        token1.mint(lp, ACTOR_SUPPLY);

        // Seed the pool so invariants are immediately exercisable.
        vm.startPrank(lp);
        token0.transfer(address(pair), SEED_AMOUNT);
        token1.transfer(address(pair), SEED_AMOUNT);
        vm.stopPrank();
        pair.mint(lp);

        // Build the handler.
        handler = new IntegrationHandler(factory, pair, mockLP, token0, token1, lp);

        // Restrict fuzzer to the handler, excluding the internal helper _execSwap
        // (which must be external for atomicity via `try this._execSwap(...)` but
        // should not be called directly by the fuzzer engine).
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.doMint.selector;
        selectors[1] = handler.doSwap.selector;
        selectors[2] = handler.doBurn.selector;
        selectors[3] = handler.doFreeze.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    // -------------------------------------------------------------------------
    // Invariants
    // -------------------------------------------------------------------------

    /// @notice Accounting identity: getReserves() == physical + supplied for each token.
    function invariant_totalReserveEqualsPhysicalPlusSupplied() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint112 s0, uint112 s1) = pair.suppliedReserves();
        uint256 phys0 = IERC20(pair.token0()).balanceOf(address(pair));
        uint256 phys1 = IERC20(pair.token1()).balanceOf(address(pair));
        assertEq(r0, phys0 + s0, "totalReserve0 != physical0 + supplied0");
        assertEq(r1, phys1 + s1, "totalReserve1 != physical1 + supplied1");
    }

    /// @notice supplied_i can never exceed the total reserve of that token.
    function invariant_suppliedNeverExceedsTotalReserve() public view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint112 s0, uint112 s1) = pair.suppliedReserves();
        assertLe(s0, r0, "supplied0 > totalReserve0");
        assertLe(s1, r1, "supplied1 > totalReserve1");
    }

    // -------------------------------------------------------------------------
    // Post-run sanity check
    // -------------------------------------------------------------------------

    /// @notice At least one successful mint and one successful swap must have occurred.
    function afterInvariant() public view {
        assertGt(handler.ghost_mintCalls(), 0, "no mint calls succeeded across the entire run");
        assertGt(handler.ghost_swapCalls(), 0, "no swap calls succeeded across the entire run");
    }
}
