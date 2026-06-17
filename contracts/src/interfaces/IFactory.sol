// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IFactory
/// @notice Interface for the Pair factory/registry.
/// @dev invariant: for any two distinct tokens (A, B), `getPair(A, B) == getPair(B, A)`
///      and resolves to at most one `Pair` contract. Pairs are deployed with `new Pair()`
///      (CREATE, not CREATE2), so addresses are not deterministic off-chain.
interface IFactory {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a new pair is created.
    /// @param token0 The first token of the pair, sorted by address.
    /// @param token1 The second token of the pair, sorted by address.
    /// @param pair Address of the newly deployed `Pair` contract.
    /// @param allPairsLength The total number of pairs created so far (after this one).
    event PairCreated(
        address indexed token0, address indexed token1, address pair, uint256 allPairsLength
    );

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice The address that owns this factory (can set lending pools on pairs).
    function owner() external view returns (address);

    /// @notice Returns the pair address for `tokenA`/`tokenB`, or `address(0)` if none exists.
    /// @dev Order-independent: `getPair(tokenA, tokenB) == getPair(tokenB, tokenA)`.
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    /// @notice Returns the pair address at index `index` in the order they were created.
    function allPairs(uint256 index) external view returns (address pair);

    /// @notice Returns the total number of pairs created by this factory.
    function allPairsLength() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Mutators
    // -------------------------------------------------------------------------

    /// @notice Deploys a new `Pair` for `tokenA`/`tokenB` if one does not already exist.
    /// @param tokenA First token of the pair (any order).
    /// @param tokenB Second token of the pair (any order).
    /// @return pair Address of the (newly created or existing) pair.
    function createPair(address tokenA, address tokenB) external returns (address pair);

    /// @notice Configures the lending pool integration for `pair`.
    /// @dev Only callable by the factory `owner`. Delegates to `IPair.setLendingPool`.
    /// @param pair      Address of the pair to configure.
    /// @param pool      Address of the `ILendingPool`, or `address(0)` to disable.
    /// @param bufferBps Minimum liquid fraction (basis points) to keep in the pair.
    function setPairLendingPool(address pair, address pool, uint16 bufferBps) external;
}
