// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { TestToken } from "../src/tokens/TestToken.sol";
import { Factory } from "../src/amm/Factory.sol";
import { Router } from "../src/amm/Router.sol";
import { MockOracle } from "../src/oracle/MockOracle.sol";
import { LendingPool } from "../src/lending/LendingPool.sol";

/// @title Deploy
/// @notice Demo deployment script for the YieldPair stack (AMM + lending, idle-reserve
///         sweeping) — wires two mock tokens, a Pair/Router/Factory, a MockOracle, and a
///         LendingPool, seeds the pair with liquidity, and opens a demo borrow position.
/// @dev invariant: this script makes no protocol-level state assumption beyond what each
///      contract already enforces — it only sequences calls in the exact order required by
///      their own access control (e.g. lending markets must be listed and the pair's lending
///      pool must be wired *before* the liquidity seed, so the very first `mint` already
///      sweeps idle liquidity into the lending pool).
/// @dev Reads the deployer's private key from the `PRIVATE_KEY` env var — never hardcode keys.
///      Run against Sepolia with:
///        forge script script/Deploy.s.sol:Deploy --rpc-url sepolia --broadcast --verify -vvvv
///      Dry-run (simulation only, no `--broadcast`) against a local anvil instance:
///        forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545
contract Deploy is Script {
    // -------------------------------------------------------------------------
    // Demo scenario parameters (see plan FASE 4 for rationale)
    // -------------------------------------------------------------------------

    uint256 internal constant MUSDC_INITIAL_SUPPLY = 10_000_000e18;
    uint256 internal constant MWETH_INITIAL_SUPPLY = 10_000e18;

    uint256 internal constant MUSDC_PRICE = 1e18; // $1.00
    uint256 internal constant MWETH_PRICE = 3000e18; // $3,000.00

    uint256 internal constant MUSDC_COLLATERAL_FACTOR = 0.8e18;
    uint256 internal constant MWETH_COLLATERAL_FACTOR = 0.75e18;

    /// @dev 20% (2000 bps) kept liquid in the pair; rest is swept to the lending pool.
    uint16 internal constant BUFFER_BPS = 2000;

    /// @dev Seed liquidity at the oracle price ratio (~3000 mUSDC per mWETH).
    uint256 internal constant SEED_MUSDC = 3_000_000e18;
    uint256 internal constant SEED_MWETH = 1_000e18;

    /// @dev Demo borrow position opened by the deployer as a second actor.
    uint256 internal constant DEMO_SUPPLY_MWETH = 10e18;
    uint256 internal constant DEMO_BORROW_MUSDC = 9_000e18;

    /// @dev Deadline window for the Router's `ensure(deadline)` modifier.
    uint256 internal constant DEADLINE_WINDOW = 1 hours;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the two mock tokens, minting the full initial supply to the deployer.
        TestToken mUSDC = new TestToken("Mock USDC", "mUSDC", MUSDC_INITIAL_SUPPLY);
        TestToken mWETH = new TestToken("Mock WETH", "mWETH", MWETH_INITIAL_SUPPLY);

        // 2. Deploy the Factory (owner = deployer).
        Factory factory = new Factory();

        // 3. Deploy the Router, wired to the Factory.
        Router router = new Router(address(factory));

        // 4. Create the mUSDC/mWETH pair.
        address pair = factory.createPair(address(mUSDC), address(mWETH));

        // 5. Deploy the MockOracle and set both prices.
        MockOracle oracle = new MockOracle(deployer);
        oracle.setPrice(address(mUSDC), MUSDC_PRICE);
        oracle.setPrice(address(mWETH), MWETH_PRICE);

        // 6. Deploy the LendingPool against that oracle.
        LendingPool lendingPool = new LendingPool(deployer, oracle);

        // 7. List both markets BEFORE the liquidity seed, so the pair's first sweep
        //    (triggered by `mint` in step 9) has a market to supply into.
        lendingPool.listMarket(address(mUSDC), MUSDC_COLLATERAL_FACTOR);
        lendingPool.listMarket(address(mWETH), MWETH_COLLATERAL_FACTOR);

        // 8. Wire the lending pool into the pair via the Factory (factory-gated —
        //    `Pair.setLendingPool` itself is NOT called directly). Done BEFORE the seed
        //    so the first `mint` already sweeps idle liquidity into the lending pool.
        factory.setPairLendingPool(pair, address(lendingPool), BUFFER_BPS);

        // 9. Seed liquidity through the Router. `Pair._sweepExcess` uses `forceApprove`
        //    internally, so only the deployer -> Router approvals are needed here.
        mUSDC.approve(address(router), SEED_MUSDC);
        mWETH.approve(address(router), SEED_MWETH);
        router.addLiquidity(
            address(mUSDC),
            address(mWETH),
            SEED_MUSDC,
            SEED_MWETH,
            0,
            0,
            deployer,
            block.timestamp + DEADLINE_WINDOW
        );

        // 10. Demo position: deployer supplies mWETH as collateral and borrows mUSDC.
        //     HF ~= (10 * 3000 * 0.75) / 9000 = 2.5 (healthy, visible on the dashboard).
        //     The mUSDC cash for this borrow comes from the sweep in step 9.
        mWETH.approve(address(lendingPool), DEMO_SUPPLY_MWETH);
        lendingPool.supply(address(mWETH), DEMO_SUPPLY_MWETH);
        lendingPool.borrow(address(mUSDC), DEMO_BORROW_MUSDC);

        vm.stopBroadcast();

        console2.log("Deployer       :", deployer);
        console2.log("mUSDC          :", address(mUSDC));
        console2.log("mWETH          :", address(mWETH));
        console2.log("Factory        :", address(factory));
        console2.log("Router         :", address(router));
        console2.log("Pair           :", pair);
        console2.log("MockOracle     :", address(oracle));
        console2.log("LendingPool    :", address(lendingPool));

        _writeDeployment(
            address(mUSDC),
            address(mWETH),
            address(factory),
            address(router),
            pair,
            address(oracle),
            address(lendingPool)
        );
    }

    /// @dev Serializes all deployed addresses plus chain/block metadata to
    ///      `<repo-root>/deployments/sepolia.json`. Creates the `deployments/` directory
    ///      (at the repo root, NOT inside `contracts/`) on first run via `vm.writeJson`.
    function _writeDeployment(
        address mUSDC,
        address mWETH,
        address factory,
        address router,
        address pair,
        address oracle,
        address lendingPool
    ) internal {
        string memory key = "deployment";

        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "blockNumber", block.number);
        vm.serializeAddress(key, "mUSDC", mUSDC);
        vm.serializeAddress(key, "mWETH", mWETH);
        vm.serializeAddress(key, "factory", factory);
        vm.serializeAddress(key, "router", router);
        vm.serializeAddress(key, "pair", pair);
        vm.serializeAddress(key, "oracle", oracle);
        string memory finalJson = vm.serializeAddress(key, "lendingPool", lendingPool);

        string memory outDir = string.concat(vm.projectRoot(), "/../deployments");
        vm.createDir(outDir, true);
        vm.writeJson(finalJson, string.concat(outDir, "/sepolia.json"));
    }
}
