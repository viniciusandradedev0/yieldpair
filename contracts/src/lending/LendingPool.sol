// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { ILendingPool } from "../interfaces/ILendingPool.sol";

/// @title LendingPool
/// @notice Multi-asset collateralized lending pool with a linear interest rate model.
///
/// @dev Solvency invariant (maintained for every listed market at all times):
///          IERC20(token).balanceOf(address(this)) + market.totalBorrows >= market.totalSupplied
///      Equivalently: cash + borrows >= supplied.
///      This guarantees every depositor can be made whole once all borrowers repay.
///
/// @dev Index invariants:
///      - `market.borrowIndex` is monotonically non-decreasing (starts at WAD).
///      - `market.supplyIndex`  is monotonically non-decreasing (starts at WAD).
///
/// @dev Rounding policy — always round against the user / in favor of the pool:
///      - debtOf (user owes)      → ROUND UP   (Math.mulDiv Ceil)
///      - supplyBalanceOf (user gets) → ROUND DOWN (plain division)
///      - seizeShares (col to seize)  → ROUND UP   (user loses slightly more — safe)
///      - shares to burn on withdraw  → ROUND UP   then capped (user burns slightly more)
///      - all interest accrual math   → ROUND DOWN (pool keeps any dust)
///
/// @dev CEI order in every state-changing function:
///      1. accrueInterest  (FIRST — all later math uses up-to-date indexes)
///      2. Input validation
///      3. State mutations
///      4. Health-factor check (BEFORE any external transfer)
///      5. SafeTransfer / SafeTransferFrom (LAST)
///
/// @dev Oracle safety: `oracle.getPrice` is NEVER called inside `accrueInterest`.
///      Interest does not depend on price; mixing the two would allow flash-loan
///      price manipulation to affect interest accrual.
contract LendingPool is Ownable, ReentrancyGuard, ILendingPool {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant WAD = 1e18;

    /// @dev 2% annual base rate → per-second = floor(0.02e18 / 31_536_000)
    uint256 internal constant BASE_RATE_PER_SECOND = 634_195_840;

    /// @dev 20% annual slope at 100% utilization → per-second = floor(0.20e18 / 31_536_000)
    uint256 internal constant SLOPE_PER_SECOND = 6_341_958_400;

    /// @dev 10% of accrued interest goes to protocol reserves.
    uint256 internal constant RESERVE_FACTOR = 0.1e18;

    /// @dev Liquidator may repay at most 50% of the borrower's debt in one call.
    uint256 internal constant CLOSE_FACTOR = 0.5e18;

    /// @dev Liquidator receives 8% bonus on seized collateral (1.08x).
    uint256 internal constant LIQUIDATION_BONUS = 1.08e18;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    struct Market {
        bool listed;
        /// @dev Maximum loan-to-value for collateral, 1e18 scale (e.g. 0.75e18).
        uint256 collateralFactor;
        /// @dev Total outstanding principal + accrued interest across all borrowers.
        uint256 totalBorrows;
        /// @dev Total token value credited to suppliers (grows as interest accrues).
        uint256 totalSupplied;
        /// @dev Accumulated protocol reserves (subset of accrued interest).
        uint256 totalReserves;
        /// @dev Global borrow index, starts at WAD; used to track per-user debt growth.
        uint256 borrowIndex;
        /// @dev Global supply index, starts at WAD; used to convert shares ↔ tokens.
        uint256 supplyIndex;
        /// @dev Total supply-share units outstanding across all depositors.
        uint256 totalSupplyShares;
        /// @dev Timestamp of the last interest accrual.
        uint256 lastAccrual;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    mapping(address token => Market) internal markets;
    address[] internal marketsList;

    /// @dev Depositor's share-units for each token (shares * supplyIndex / WAD = token balance).
    mapping(address user => mapping(address token => uint256)) internal supplyShares;

    /// @dev Per-user borrow principal denominated in index-adjusted token units.
    ///      Actual debt = borrowPrincipal * currentBorrowIndex / borrowIndexSnapshot (Round UP).
    mapping(address user => mapping(address token => uint256)) internal borrowPrincipal;

    /// @dev The value of `market.borrowIndex` at the time of the user's last borrow/repay.
    mapping(address user => mapping(address token => uint256)) internal borrowIndexSnapshot;

    /// @notice Price oracle used for health-factor and liquidation computations.
    /// @dev Never queried inside `accrueInterest` — see contract-level dev note.
    IPriceOracle public immutable oracle;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error MarketNotListed(address token);
    error MarketAlreadyListed(address token);
    error ZeroAmount();
    error InsufficientCash();
    error Undercollateralized();
    error HealthyPosition();
    error SelfLiquidation();
    error RepayExceedsCloseFactor();
    error InvalidCollateralFactor();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param initialOwner  Address that receives ownership (OZ v5 Ownable).
    /// @param oracle_       Price oracle that returns USD prices with 1e18 precision.
    constructor(address initialOwner, IPriceOracle oracle_) Ownable(initialOwner) {
        oracle = oracle_;
    }

    // -------------------------------------------------------------------------
    // Owner actions
    // -------------------------------------------------------------------------

    /// @notice Lists a new ERC20 token as a market.
    /// @dev Initializes indexes at WAD and lastAccrual at the current timestamp.
    ///      `collateralFactor` must satisfy `collateralFactor * LIQUIDATION_BONUS < WAD`
    ///      (i.e. cf < WAD / 1.08 ≈ 0.9259e18). If violated, each liquidation would
    ///      remove more collateral value than debt value, causing HF to decrease after
    ///      liquidation — a death-spiral leading to bad debt.
    /// @param token            ERC20 token to list.
    /// @param collateralFactor Maximum LTV in 1e18 scale; must be < WAD/LIQUIDATION_BONUS.
    function listMarket(address token, uint256 collateralFactor) external onlyOwner {
        if (markets[token].listed) revert MarketAlreadyListed(token);
        if (collateralFactor == 0 || (collateralFactor * LIQUIDATION_BONUS) / WAD >= WAD) {
            revert InvalidCollateralFactor();
        }

        markets[token] = Market({
            listed: true,
            collateralFactor: collateralFactor,
            totalBorrows: 0,
            totalSupplied: 0,
            totalReserves: 0,
            borrowIndex: WAD,
            supplyIndex: WAD,
            totalSupplyShares: 0,
            lastAccrual: block.timestamp
        });
        marketsList.push(token);

        emit MarketListed(token, collateralFactor);
    }

    // -------------------------------------------------------------------------
    // Interest accrual
    // -------------------------------------------------------------------------

    /// @notice Accrues outstanding interest for `token`'s market.
    /// @dev Safe to call multiple times in a block — returns early when dt == 0.
    ///      Does NOT read oracle prices (see contract-level dev note).
    ///      All arithmetic rounds DOWN to keep any dust in the pool.
    function accrueInterest(address token) public {
        Market storage m = markets[token];
        if (!m.listed) revert MarketNotListed(token);

        uint256 dt = block.timestamp - m.lastAccrual;
        if (dt == 0) return;

        // Fast path: no borrows → no interest to distribute.
        if (m.totalBorrows == 0) {
            m.lastAccrual = block.timestamp;
            return;
        }

        // Utilization: borrows / (cash + borrows). ROUND DOWN.
        uint256 cash = IERC20(token).balanceOf(address(this));
        uint256 util = (m.totalBorrows * WAD) / (cash + m.totalBorrows);

        // Borrow rate per second (1e18 scale). ROUND DOWN.
        uint256 rate = BASE_RATE_PER_SECOND + (SLOPE_PER_SECOND * util) / WAD;

        // Interest factor = rate * dt (still 1e18 scale, no extra division needed).
        uint256 interestFactor = rate * dt;

        // Accrued borrow interest. ROUND DOWN (pool keeps dust).
        uint256 accruedBorrow = (m.totalBorrows * interestFactor) / WAD;

        // Reserve slice. ROUND DOWN.
        uint256 reserve = (accruedBorrow * RESERVE_FACTOR) / WAD;

        // Supplier slice.
        uint256 toSuppliers = accruedBorrow - reserve;

        // Update borrow index. ROUND DOWN.
        m.borrowIndex += (m.borrowIndex * interestFactor) / WAD;

        // Update supply index only when there are outstanding shares to credit.
        // ROUND DOWN — suppliers receive slightly less than exact; dust stays in pool.
        if (m.totalSupplied > 0 && toSuppliers > 0) {
            m.supplyIndex += (m.supplyIndex * toSuppliers) / m.totalSupplied;
        }

        m.totalBorrows += accruedBorrow;
        m.totalReserves += reserve;
        m.totalSupplied += toSuppliers;
        m.lastAccrual = block.timestamp;

        emit AccrueInterest(token, m.borrowIndex, m.totalBorrows);
    }

    // -------------------------------------------------------------------------
    // Supply / Withdraw
    // -------------------------------------------------------------------------

    /// @notice Deposit `amount` of `token` into the pool.
    /// @dev CEI: accrue → validate → state → transfer → emit.
    ///      Shares are minted proportional to the current supplyIndex.
    ///      On the very first deposit (totalSupplyShares == 0) shares == amount,
    ///      which anchors supplyIndex == WAD correctly.
    ///      Shares calculation rounds DOWN → user gets slightly fewer shares than
    ///      the exact proportion, which is safe for the pool.
    function supply(address token, uint256 amount) external nonReentrant {
        // 1. Accrue interest first so supplyIndex is current.
        accrueInterest(token);

        // 2. Validate.
        if (amount == 0) revert ZeroAmount();
        // `accrueInterest` already checked `listed`; no duplicate check needed.

        Market storage m = markets[token];

        // 3. Compute shares. ROUND DOWN — user receives fewer shares, pool is safer.
        uint256 shares;
        if (m.totalSupplyShares == 0) {
            // First deposit: 1 share == 1 token (anchors supplyIndex at WAD).
            shares = amount;
        } else {
            // shares = amount * WAD / supplyIndex  (ROUND DOWN)
            shares = (amount * WAD) / m.supplyIndex;
            // Guard: if supplyIndex has grown enough that a tiny `amount` rounds to
            // 0 shares, the tokens would be donated to the pool with no credit given.
            if (shares == 0) revert ZeroAmount();
        }

        // 4. State mutations (before transfer — CEI).
        supplyShares[msg.sender][token] += shares;
        m.totalSupplyShares += shares;
        m.totalSupplied += amount;

        // 5. Pull tokens from caller.
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Supply(msg.sender, token, amount, shares);
    }

    /// @notice Withdraw `amount` of `token` from the pool.
    /// @dev CEI: accrue → validate → state → HF check → transfer → emit.
    ///      Shares burned round UP so the pool is not over-credited, then capped
    ///      at the user's actual balance to avoid rounding above what they own.
    ///      The actual token amount sent out is recalculated from the capped shares
    ///      (ROUND DOWN), so the user may receive infinitesimally less than requested.
    function withdraw(address token, uint256 amount) external nonReentrant {
        // 1. Accrue.
        accrueInterest(token);

        // 2. Validate.
        if (amount == 0) revert ZeroAmount();

        Market storage m = markets[token];
        uint256 userBalance = _supplyBalanceOf(msg.sender, token, m.supplyIndex);
        if (amount > userBalance) revert InsufficientCash();

        // 3. Compute shares to burn.
        //    ROUND UP — burns a tiny bit more so the pool is not over-credited.
        uint256 shares = Math.mulDiv(amount, WAD, m.supplyIndex, Math.Rounding.Ceil);

        // Cap at user's actual shares — prevents burning more than they own.
        uint256 userShares = supplyShares[msg.sender][token];
        if (shares > userShares) shares = userShares;

        // Actual token amount that leaves the pool (ROUND DOWN — pool keeps any dust).
        uint256 actualAmount = (shares * m.supplyIndex) / WAD;

        // 4. Check available cash.
        if (IERC20(token).balanceOf(address(this)) < actualAmount) revert InsufficientCash();

        // 5. State mutations.
        supplyShares[msg.sender][token] = userShares - shares;
        m.totalSupplyShares -= shares;
        // Protect against underflow from rounding; floor at 0.
        m.totalSupplied = m.totalSupplied > actualAmount ? m.totalSupplied - actualAmount : 0;

        // 6. Health-factor check BEFORE transfer — borrowers must remain solvent.
        //    Only needed if the user has active borrows anywhere.
        if (_hasBorrows(msg.sender)) {
            if (healthFactor(msg.sender) < WAD) revert Undercollateralized();
        }

        // 7. Transfer tokens out.
        IERC20(token).safeTransfer(msg.sender, actualAmount);

        emit Withdraw(msg.sender, token, actualAmount, shares);
    }

    // -------------------------------------------------------------------------
    // Borrow / Repay
    // -------------------------------------------------------------------------

    /// @notice Borrow `amount` of `token` from the pool.
    /// @dev CEI: accrue → validate → state → HF check → transfer → emit.
    ///      For an existing borrow, the principal is normalised to the current index
    ///      before adding the new amount, so the user's effective interest is
    ///      always computed from a single consistent snapshot.
    function borrow(address token, uint256 amount) external nonReentrant {
        // 1. Accrue.
        accrueInterest(token);

        // 2. Validate.
        if (amount == 0) revert ZeroAmount();
        // Market liveness already guaranteed by accrueInterest.

        Market storage m = markets[token];

        // 3. Check cash.
        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientCash();

        // 4. State: update borrow records.
        uint256 existingPrincipal = borrowPrincipal[msg.sender][token];
        if (existingPrincipal == 0) {
            // New borrow: snapshot current index and record principal.
            borrowIndexSnapshot[msg.sender][token] = m.borrowIndex;
            borrowPrincipal[msg.sender][token] = amount;
        } else {
            // Existing borrow: normalise outstanding debt to current index first
            // (ROUND UP — user owes the extra dust, not the pool).
            uint256 currentDebt = Math.mulDiv(
                existingPrincipal,
                m.borrowIndex,
                borrowIndexSnapshot[msg.sender][token],
                Math.Rounding.Ceil
            );
            borrowPrincipal[msg.sender][token] = currentDebt + amount;
            borrowIndexSnapshot[msg.sender][token] = m.borrowIndex;
        }
        m.totalBorrows += amount;

        // 5. HF check BEFORE transfer — reverts if position would become undercollateralised.
        if (healthFactor(msg.sender) < WAD) revert Undercollateralized();

        // 6. Send tokens to borrower.
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, token, amount);
    }

    /// @notice Repay up to `amount` of `token` debt on behalf of `onBehalfOf`.
    /// @dev CEI: accrue → validate → state → transfer → emit.
    ///      `repayAmount` is capped at the current debt so callers can pass
    ///      `type(uint256).max` to repay in full without knowing the exact amount.
    function repay(address token, uint256 amount, address onBehalfOf) external nonReentrant {
        // 1. Accrue.
        accrueInterest(token);

        // 2. Validate.
        if (amount == 0) revert ZeroAmount();

        uint256 debt = debtOf(onBehalfOf, token);
        if (debt == 0) revert ZeroAmount(); // no debt to repay

        // 3. Cap repay at actual debt.
        uint256 repayAmount = amount > debt ? debt : amount;

        // 4. State mutations.
        _applyRepay(onBehalfOf, token, repayAmount, debt);

        // 5. Pull tokens from caller (msg.sender pays, even if onBehalfOf differs).
        IERC20(token).safeTransferFrom(msg.sender, address(this), repayAmount);

        emit Repay(msg.sender, onBehalfOf, token, repayAmount);
    }

    // -------------------------------------------------------------------------
    // Liquidation
    // -------------------------------------------------------------------------

    /// @notice Liquidate an undercollateralised position.
    /// @dev CEI: accrue both markets → guards → state (repay + seize) → transfer → emit.
    ///      The liquidator sends `repayAmount` of `debtToken` and receives
    ///      `seizeAmount` of `collateralToken` (at an 8% bonus).
    ///      seizeShares rounds UP — borrower loses a tiny bit more, which is safe
    ///      (the cap prevents taking more than the borrower actually holds).
    function liquidate(
        address borrower,
        address debtToken,
        address collateralToken,
        uint256 repayAmount
    ) external nonReentrant returns (uint256 seizeAmount) {
        // 1. Accrue both markets first (CEI: state changes come after).
        accrueInterest(debtToken);
        accrueInterest(collateralToken);

        // 2. Guards.
        if (borrower == msg.sender) revert SelfLiquidation();
        if (healthFactor(borrower) >= WAD) revert HealthyPosition();

        // 3. Close-factor cap + seize computation (split into helper to avoid stack overflow).
        uint256 debt = debtOf(borrower, debtToken);
        // maxRepay rounds DOWN — liquidator can repay slightly less than exact 50%
        // which is conservative and prevents the invariant from being violated.
        if (repayAmount > (debt * CLOSE_FACTOR) / WAD) revert RepayExceedsCloseFactor();

        seizeAmount = _computeSeize(borrower, collateralToken, debtToken, repayAmount);

        // 4. State: repay borrower's debt.
        _applyRepay(borrower, debtToken, repayAmount, debt);

        // 5. State: seize collateral shares from borrower, credit to liquidator.
        _applySeize(borrower, collateralToken, seizeAmount);

        // 6. Pull repayment from liquidator.
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), repayAmount);

        emit Liquidate(msg.sender, borrower, debtToken, collateralToken, repayAmount, seizeAmount);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the current debt of `user` for `token`, rounded UP.
    /// @dev Does NOT accrue interest — the returned value may be slightly stale
    ///      if called between accrual intervals. Always call `accrueInterest` first
    ///      in any state-changing path that uses this value.
    ///      ROUND UP (Math.Rounding.Ceil) — user owes the extra dust, not the pool.
    function debtOf(address user, address token) public view returns (uint256) {
        uint256 principal = borrowPrincipal[user][token];
        if (principal == 0) return 0;
        uint256 snapshot = borrowIndexSnapshot[user][token];
        uint256 currentIndex = markets[token].borrowIndex;
        // debt = principal * currentIndex / snapshot  ROUND UP
        return Math.mulDiv(principal, currentIndex, snapshot, Math.Rounding.Ceil);
    }

    /// @notice Returns the current supply balance of `user` for `token`, rounded DOWN.
    /// @dev shares * supplyIndex / WAD  ROUND DOWN — user receives slightly less.
    function supplyBalanceOf(address user, address token) public view returns (uint256) {
        return _supplyBalanceOf(user, token, markets[token].supplyIndex);
    }

    /// @notice Returns the current utilization rate for `token`, in 1e18 scale.
    function utilization(address token) public view returns (uint256) {
        Market storage m = markets[token];
        uint256 cash = IERC20(token).balanceOf(address(this));
        uint256 borrows = m.totalBorrows;
        if (cash + borrows == 0) return 0;
        return (borrows * WAD) / (cash + borrows);
    }

    /// @notice Returns the borrow rate per second for `token`, in 1e18 scale.
    function borrowRatePerSecond(address token) external view returns (uint256) {
        uint256 util = utilization(token);
        return BASE_RATE_PER_SECOND + (SLOPE_PER_SECOND * util) / WAD;
    }

    /// @notice Returns the health factor of `user` in 1e18 scale.
    /// @dev Iterates over all listed markets. Returns `type(uint256).max` if debt == 0.
    ///      IMPORTANT: reverts if any listed market has no price configured in the oracle.
    ///      All markets listed in this pool MUST have a price set in the oracle at all times.
    ///
    ///      collateralValue accumulation: ROUND DOWN (user gets less credit).
    ///      debtValue accumulation: uses debtOf which rounds UP.
    function healthFactor(address user) public view returns (uint256) {
        uint256 collateralValue;
        uint256 debtValue;

        uint256 len = marketsList.length;
        for (uint256 i; i < len; ++i) {
            address token = marketsList[i];
            Market storage m = markets[token];

            uint256 price = oracle.getPrice(token); // reverts PriceNotSet if unconfigured

            // Collateral contribution: balance * price * cf / WAD^2  ROUND DOWN
            uint256 bal = _supplyBalanceOf(user, token, m.supplyIndex);
            if (bal > 0) {
                uint256 col = (bal * price) / WAD;
                col = (col * m.collateralFactor) / WAD;
                collateralValue += col;
            }

            // Debt contribution: debtOf rounds UP (conservative, favors pool)
            uint256 debt = debtOf(user, token);
            if (debt > 0) {
                debtValue += (debt * price) / WAD;
            }
        }

        if (debtValue == 0) return type(uint256).max;
        return (collateralValue * WAD) / debtValue;
    }

    // -------------------------------------------------------------------------
    // Inspection helpers (test / integration use)
    // -------------------------------------------------------------------------

    /// @notice Returns the raw storage fields of a listed market.
    /// @dev Intended for off-chain tooling and test suites that need to verify
    ///      the solvency invariant without relying on per-user view functions.
    function getMarket(address token)
        external
        view
        returns (
            uint256 totalBorrows,
            uint256 totalSupplied,
            uint256 totalReserves,
            uint256 borrowIndex,
            uint256 supplyIndex,
            uint256 lastAccrual
        )
    {
        Market storage m = markets[token];
        return (
            m.totalBorrows,
            m.totalSupplied,
            m.totalReserves,
            m.borrowIndex,
            m.supplyIndex,
            m.lastAccrual
        );
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Computes supply balance without an external storage read for the index.
    ///      ROUND DOWN — pool keeps dust on the user's behalf.
    function _supplyBalanceOf(address user, address token, uint256 currentSupplyIndex)
        internal
        view
        returns (uint256)
    {
        return (supplyShares[user][token] * currentSupplyIndex) / WAD;
    }

    /// @dev Returns true if `user` has any outstanding borrow across all markets.
    ///      Used to skip the health-factor check on `withdraw` for pure suppliers.
    function _hasBorrows(address user) internal view returns (bool) {
        uint256 len = marketsList.length;
        for (uint256 i; i < len; ++i) {
            if (borrowPrincipal[user][marketsList[i]] > 0) return true;
        }
        return false;
    }

    /// @dev Computes the collateral seize amount for a liquidation.
    ///      Split out from `liquidate` to avoid a stack-too-deep error.
    ///      seizeValue = repayAmount * priceDebt / WAD * LIQUIDATION_BONUS / WAD  ROUND DOWN
    ///      seizeAmount = seizeValue * WAD / priceCollateral                      ROUND DOWN
    function _computeSeize(
        address borrower,
        address collateralToken,
        address debtToken,
        uint256 repayAmount
    ) internal view returns (uint256 seizeAmount) {
        uint256 priceDebt = oracle.getPrice(debtToken);
        uint256 priceCollateral = oracle.getPrice(collateralToken);

        uint256 seizeValue = (repayAmount * priceDebt) / WAD;
        seizeValue = (seizeValue * LIQUIDATION_BONUS) / WAD;
        seizeAmount = (seizeValue * WAD) / priceCollateral;

        // Cap at borrower's actual collateral balance.
        uint256 borrowerCollateral =
            _supplyBalanceOf(borrower, collateralToken, markets[collateralToken].supplyIndex);
        if (seizeAmount > borrowerCollateral) seizeAmount = borrowerCollateral;
    }

    /// @dev Transfers `seizeAmount` worth of collateral shares from `borrower` to `msg.sender`.
    ///      seizeShares rounds UP — borrower loses slightly more; the cap keeps it bounded.
    ///      totalSupplyShares and totalSupplied are unchanged — ownership is transferred,
    ///      not withdrawn, so the solvency invariant (cash + borrows >= supplied) is preserved.
    function _applySeize(address borrower, address collateralToken, uint256 seizeAmount) internal {
        uint256 colSupplyIndex = markets[collateralToken].supplyIndex;
        // ROUND UP — borrower loses a tiny bit more, keeping the pool safer.
        uint256 seizeShares = Math.mulDiv(seizeAmount, WAD, colSupplyIndex, Math.Rounding.Ceil);

        // Cap at borrower's actual shares (guards against rounding pushing above holding).
        uint256 borrowerShares = supplyShares[borrower][collateralToken];
        if (seizeShares > borrowerShares) seizeShares = borrowerShares;

        supplyShares[borrower][collateralToken] = borrowerShares - seizeShares;
        supplyShares[msg.sender][collateralToken] += seizeShares;
    }

    /// @dev Applies a repayment of `repayAmount` against `user`'s debt in `token`.
    ///      `currentDebt` must be the value of `debtOf(user, token)` computed
    ///      immediately before this call (avoids a redundant round-trip).
    ///      If the position is fully repaid, principal and snapshot are zeroed.
    ///      Otherwise the principal is restated at the current index. ROUND DOWN
    ///      for the new stored principal — user may owe a tiny extra dust next call,
    ///      which is acceptable and keeps the pool slightly safer.
    function _applyRepay(address user, address token, uint256 repayAmount, uint256 currentDebt)
        internal
    {
        Market storage m = markets[token];
        uint256 newDebt = currentDebt - repayAmount;

        if (newDebt == 0) {
            borrowPrincipal[user][token] = 0;
            borrowIndexSnapshot[user][token] = 0;
        } else {
            // Store normalised principal at the current index. ROUND DOWN —
            // slightly understates principal, meaning the next debtOf call (which
            // rounds UP) will recover any dust, keeping the pool safe.
            borrowPrincipal[user][token] = (newDebt * WAD) / m.borrowIndex;
            borrowIndexSnapshot[user][token] = m.borrowIndex;
        }

        // Protect against underflow from rounding; floor totalBorrows at 0.
        m.totalBorrows = m.totalBorrows > repayAmount ? m.totalBorrows - repayAmount : 0;
    }
}
