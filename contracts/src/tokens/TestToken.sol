// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestToken
/// @notice Minimal testnet/faucet ERC20 with 18 decimals (OZ default).
/// @dev invariant: total supply only ever changes via the open `mint` function below
///      (no burn is exposed) — by design `mint` is callable by anyone, since this
///      token is intended exclusively for testnets/faucets and must never be
///      deployed to a chain where its supply needs to be trusted.
contract TestToken is ERC20 {
    /// @param name_ ERC20 name.
    /// @param symbol_ ERC20 symbol.
    /// @param initialSupply Amount (in wei, 18 decimals) minted to `msg.sender` at deploy.
    ///        Pass 0 to skip the initial mint.
    constructor(string memory name_, string memory symbol_, uint256 initialSupply)
        ERC20(name_, symbol_)
    {
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    /// @notice Mints `amount` tokens to `to`. Intentionally unrestricted (faucet token).
    /// @dev Open mint is a deliberate testnet-only design choice — do NOT reuse this
    ///      contract pattern for any token meant to hold real value.
    /// @param to Recipient of the minted tokens.
    /// @param amount Amount to mint, in wei (18 decimals).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
