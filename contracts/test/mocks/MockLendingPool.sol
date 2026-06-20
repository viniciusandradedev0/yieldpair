// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILendingPool } from "../../src/interfaces/ILendingPool.sol";

/// @title MockLendingPool
/// @notice Minimal mock of `ILendingPool` used exclusively in integration tests.
///
/// @dev `supply` pulls tokens from the caller via `transferFrom` (i.e. the Pair must
///      `forceApprove` before calling, which it does in `_sweepExcess`).
///      `withdraw` sends tokens back to the caller (`msg.sender`), which is the Pair.
///
///      When `frozen == true`, `withdraw` reverts — simulating a lending pool under
///      maximum utilisation that cannot honour immediate withdrawals.
///
///      All other ILendingPool functions are implemented as no-op stubs so the
///      contract compiles without abstract-contract errors.
contract MockLendingPool is ILendingPool {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Principal deposited per token (does not accrue interest in the mock).
    mapping(address => uint256) public deposited;

    /// @notice When true, `withdraw` reverts unconditionally.
    bool public frozen;

    // -------------------------------------------------------------------------
    // Control helpers (test-only)
    // -------------------------------------------------------------------------

    /// @notice Freeze the pool so all `withdraw` calls revert.
    function freeze() external {
        frozen = true;
    }

    /// @notice Unfreeze the pool so `withdraw` calls succeed again.
    function unfreeze() external {
        frozen = false;
    }

    // -------------------------------------------------------------------------
    // ILendingPool — core functions
    // -------------------------------------------------------------------------

    /// @notice Pulls `amount` of `token` from `msg.sender` and records the principal.
    /// @dev The Pair calls `IERC20(token).forceApprove(lendingPool, excess)` before
    ///      invoking this, so the `transferFrom` will succeed.
    function supply(address token, uint256 amount) external override {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        deposited[token] += amount;
        emit Supply(msg.sender, token, amount, amount); // shares == amount in the mock
    }

    /// @notice Sends `amount` of `token` to `msg.sender` (the Pair).
    /// @dev Reverts if `frozen` (simulates high utilisation) or if there is not
    ///      enough deposited principal.
    function withdraw(address token, uint256 amount) external override {
        require(!frozen, "MockLendingPool: frozen");
        require(deposited[token] >= amount, "MockLendingPool: insufficient deposited");
        deposited[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, token, amount, amount); // shares == amount in the mock
    }

    // -------------------------------------------------------------------------
    // ILendingPool — stub implementations (required by the interface)
    // -------------------------------------------------------------------------

    function listMarket(address, uint256) external override { }

    function borrow(address, uint256) external override { }

    function repay(address, uint256, address) external override { }

    function liquidate(address, address, address, uint256)
        external
        override
        returns (uint256 seizeAmount)
    {
        return 0;
    }

    function accrueInterest(address) external override { }

    function healthFactor(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function debtOf(address, address) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Returns the principal deposited for `token` (the mock accrues no interest,
    ///         so shares are always 1:1 with the underlying — this mirrors a real
    ///         `LendingPool.supplyBalanceOf` with `supplyIndex == WAD`).
    function supplyBalanceOf(address, address token) external view override returns (uint256) {
        return deposited[token];
    }

    function utilization(address) external pure override returns (uint256) {
        return 0;
    }

    function borrowRatePerSecond(address) external pure override returns (uint256) {
        return 0;
    }
}
