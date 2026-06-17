// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IPriceOracle } from "../interfaces/IPriceOracle.sol";

/// @title MockOracle
/// @notice Owner-controlled price feed for testnet use.
/// @dev NEVER use this in production — prices are set by a single trusted owner with no
///      time-lock or TWAP protection. A flash-loan attack can manipulate any AMM spot price
///      read in the same transaction; only a time-weighted or external oracle is safe for
///      production lending.
contract MockOracle is Ownable, IPriceOracle {
    /// @notice Emitted when the owner updates the price of a token.
    event PriceSet(address indexed token, uint256 price);

    /// @notice Thrown when `getPrice` is called for a token with no price set.
    error PriceNotSet(address token);

    /// @dev token address => price (1e18 == $1.00).
    mapping(address => uint256) private prices;

    /// @param initialOwner Address that will own this oracle (OZ v5 Ownable).
    constructor(address initialOwner) Ownable(initialOwner) { }

    /// @notice Sets the USD price for `token`.
    /// @dev 1e18 == $1.00. Setting price to 0 is allowed — it effectively delists the
    ///      token because `getPrice` will then revert `PriceNotSet`.
    /// @param token  Address of the token.
    /// @param price  Price in 1e18 USD.
    function setPrice(address token, uint256 price) external onlyOwner {
        prices[token] = price;
        emit PriceSet(token, price);
    }

    /// @inheritdoc IPriceOracle
    /// @dev Reverts `PriceNotSet` if no price has been configured (including price == 0).
    function getPrice(address token) external view returns (uint256) {
        uint256 price = prices[token];
        if (price == 0) revert PriceNotSet(token);
        return price;
    }
}
