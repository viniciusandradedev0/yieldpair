// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { Factory } from "../../src/amm/Factory.sol";
import { Pair } from "../../src/amm/Pair.sol";
import { IFactory } from "../../src/interfaces/IFactory.sol";
import { TestToken } from "../../src/tokens/TestToken.sol";

/// @title FactoryTest
/// @notice Unit tests for `Factory`: pair creation, deterministic token sorting,
///         symmetric registry, append-only `allPairs`, and revert paths.
contract FactoryTest is Test {
    Factory internal factory;
    TestToken internal tokenA;
    TestToken internal tokenB;

    function setUp() public {
        factory = new Factory();
        tokenA = new TestToken("Token A", "TKA", 0);
        tokenB = new TestToken("Token B", "TKB", 0);
    }

    /// @notice createPair sorts tokens (token0 < token1), records the pair
    ///         symmetrically in `getPair`, increments `allPairsLength`, and emits
    ///         `PairCreated`.
    function test_createPair_createsAndRegistersSymmetrically() public {
        (address expectedToken0, address expectedToken1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));

        // We don't know the pair address ahead of time (it's a fresh CREATE), so we
        // can't assert the exact event topic2 value without precomputing the address.
        // Compute it via the standard CREATE address formula.
        address predictedPair =
            _computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.expectEmit(true, true, false, true);
        emit IFactory.PairCreated(expectedToken0, expectedToken1, predictedPair, 1);

        address pairAddr = factory.createPair(address(tokenA), address(tokenB));

        assertEq(pairAddr, predictedPair, "pair deployed at predicted CREATE address");

        Pair pair = Pair(pairAddr);
        assertEq(pair.token0(), expectedToken0, "token0 is the lower-sorted address");
        assertEq(pair.token1(), expectedToken1, "token1 is the higher-sorted address");

        // getPair is symmetric in both directions.
        assertEq(factory.getPair(address(tokenA), address(tokenB)), pairAddr, "getPair(A,B)");
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pairAddr, "getPair(B,A)");

        assertEq(factory.allPairsLength(), 1, "allPairsLength increments to 1");
        assertEq(factory.allPairs(0), pairAddr, "allPairs[0] is the new pair");
    }

    /// @notice Creating multiple pairs increments `allPairsLength` and appends to
    ///         `allPairs` in creation order.
    function test_createPair_multiplePairs_appendOrder() public {
        TestToken tokenC = new TestToken("Token C", "TKC", 0);

        address pair1 = factory.createPair(address(tokenA), address(tokenB));
        address pair2 = factory.createPair(address(tokenA), address(tokenC));

        assertEq(factory.allPairsLength(), 2, "allPairsLength == 2 after two creations");
        assertEq(factory.allPairs(0), pair1, "allPairs[0] is the first pair");
        assertEq(factory.allPairs(1), pair2, "allPairs[1] is the second pair");
    }

    /// @notice createPair reverts with IdenticalAddresses if tokenA == tokenB.
    function test_createPair_revert_identicalAddresses() public {
        vm.expectRevert(Factory.IdenticalAddresses.selector);
        factory.createPair(address(tokenA), address(tokenA));
    }

    /// @notice createPair reverts with PairExists if the pair was already created,
    ///         regardless of argument order.
    function test_createPair_revert_pairExists() public {
        factory.createPair(address(tokenA), address(tokenB));

        vm.expectRevert(Factory.PairExists.selector);
        factory.createPair(address(tokenA), address(tokenB));

        // Also reverts in the reversed order.
        vm.expectRevert(Factory.PairExists.selector);
        factory.createPair(address(tokenB), address(tokenA));
    }

    /// @dev Computes the address of a contract deployed via CREATE (not CREATE2) by
    ///      `deployer` at `nonce`, per RLP-encoding rules. Mirrors
    ///      `vm.computeCreateAddress` but kept local to avoid depending on a specific
    ///      forge-std version's helper signature.
    function _computeCreateAddress(address deployer, uint256 nonce)
        internal
        pure
        returns (address)
    {
        return vm.computeCreateAddress(deployer, nonce);
    }
}
