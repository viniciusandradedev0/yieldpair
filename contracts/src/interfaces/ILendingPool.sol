// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ILendingPool {
    /// @notice Emitted when a new market is listed by the owner.
    event MarketListed(address indexed token, uint256 collateralFactor);

    /// @notice Emitted when a user supplies tokens to the pool.
    event Supply(address indexed user, address indexed token, uint256 amount, uint256 sharesMinted);

    /// @notice Emitted when a user withdraws tokens from the pool.
    event Withdraw(
        address indexed user, address indexed token, uint256 amount, uint256 sharesBurned
    );

    /// @notice Emitted when a user borrows tokens from the pool.
    event Borrow(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when debt is repaid (possibly on behalf of another user).
    event Repay(address indexed payer, address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when a liquidation is executed.
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        address debtToken,
        address collateralToken,
        uint256 repayAmount,
        uint256 seizeAmount
    );

    /// @notice Emitted whenever interest is accrued for a market.
    event AccrueInterest(address indexed token, uint256 borrowIndex, uint256 totalBorrows);

    // -------------------------------------------------------------------------
    // Owner actions
    // -------------------------------------------------------------------------

    /// @notice Lists a new token as a borrowable/collaterable market.
    /// @param token             ERC20 token address.
    /// @param collateralFactor  Maximum LTV in 1e18 scale (e.g. 0.75e18 = 75%).
    function listMarket(address token, uint256 collateralFactor) external;

    // -------------------------------------------------------------------------
    // User actions
    // -------------------------------------------------------------------------

    /// @notice Deposit `amount` of `token` into the pool, minting supply shares.
    function supply(address token, uint256 amount) external;

    /// @notice Withdraw `amount` of `token` from the pool, burning supply shares.
    function withdraw(address token, uint256 amount) external;

    /// @notice Borrow `amount` of `token` from the pool.
    function borrow(address token, uint256 amount) external;

    /// @notice Repay up to `amount` of `token` debt on behalf of `onBehalfOf`.
    function repay(address token, uint256 amount, address onBehalfOf) external;

    /// @notice Liquidate an undercollateralised position.
    /// @param borrower        Address of the user to liquidate.
    /// @param debtToken       Token the liquidator repays.
    /// @param collateralToken Token the liquidator seizes.
    /// @param repayAmount     Amount of `debtToken` the liquidator repays.
    /// @return seizeAmount    Amount of `collateralToken` the liquidator receives.
    function liquidate(
        address borrower,
        address debtToken,
        address collateralToken,
        uint256 repayAmount
    ) external returns (uint256 seizeAmount);

    // -------------------------------------------------------------------------
    // Permissionless state mutation
    // -------------------------------------------------------------------------

    /// @notice Accrue outstanding interest for `token`'s market.
    function accrueInterest(address token) external;

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Returns the health factor of `user` in 1e18 scale.
    ///         Returns `type(uint256).max` if the user has no debt.
    ///         A value < 1e18 means the position is liquidatable.
    function healthFactor(address user) external view returns (uint256);

    /// @notice Returns the current debt of `user` for `token`, rounded UP (safe for pool).
    function debtOf(address user, address token) external view returns (uint256);

    /// @notice Returns the current supply balance of `user` for `token`, rounded DOWN.
    function supplyBalanceOf(address user, address token) external view returns (uint256);

    /// @notice Returns the current utilization rate for `token` in 1e18 scale.
    function utilization(address token) external view returns (uint256);

    /// @notice Returns the borrow rate per second for `token` in 1e18 scale.
    function borrowRatePerSecond(address token) external view returns (uint256);
}
