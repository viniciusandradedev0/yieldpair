// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IFactory } from "../interfaces/IFactory.sol";
import { Pair } from "./Pair.sol";
import { AmmLibrary } from "./libraries/AmmLibrary.sol";

/// @title Factory
/// @notice Registry and deployer of `Pair` contracts for arbitrary ERC20 token pairs.
/// @dev invariant: for any two distinct tokens (A, B), `getPair[A][B] == getPair[B][A]`
///      and resolves to at most one `Pair` contract, deployed at most once. `allPairs`
///      is append-only and `allPairs.length == allPairsLength()`.
contract Factory is IFactory {
    /// @inheritdoc IFactory
    mapping(address => mapping(address => address)) public getPair;

    /// @notice All pairs ever created, in creation order.
    address[] public allPairs;

    /// @notice Thrown when `createPair` is called with `tokenA == tokenB`.
    error IdenticalAddresses();

    /// @notice Thrown when a pair for the given tokens already exists.
    error PairExists();

    /// @inheritdoc IFactory
    /// @dev Sorts `tokenA`/`tokenB` via `AmmLibrary.sortTokens` (also reverts on
    ///      `address(0)`), deploys a new `Pair`, initializes it with the sorted
    ///      tokens, and records the mapping symmetrically in both directions.
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) revert IdenticalAddresses();

        (address token0, address token1) = AmmLibrary.sortTokens(tokenA, tokenB);

        if (getPair[token0][token1] != address(0)) revert PairExists();

        pair = address(new Pair(address(this)));
        Pair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /// @inheritdoc IFactory
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }
}
