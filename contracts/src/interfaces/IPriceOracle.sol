// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IPriceOracle {
    /// @notice Returns the price of `token` denominated in USD with 1e18 precision.
    /// @dev 1e18 == $1.00. Reverts if no price is configured for `token`.
    function getPrice(address token) external view returns (uint256 price);
}
