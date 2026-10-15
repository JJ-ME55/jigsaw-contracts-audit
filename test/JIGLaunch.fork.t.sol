// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JIG} from "../src/JIG.sol";
import {PotVault} from "../src/PotVault.sol";
import {JIGLaunch} from "../src/JIGLaunch.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// Runs against a Sepolia fork: forge test --match-contract Fork --fork-url sepolia
contract JIGLaunchForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant POSM = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Launch parameters (see script/DeployJIG.s.sol for the reasoning)
    uint24 constant FEE = 10_000; // 1%
    int24 constant TICK_SPACING = 200;
    uint160 constant SQRT_PRICE = 177159557114295716651832025546752; // sqrt(5e6) * 2^96: 1 ETH = 5,000,000 JIG
    int24 constant TICK_UPPER = 154_200; // just below the start tick (~154,249)
    int24 constant TICK_LOWER = 85_200; // ~1000x above start price

    address owner = makeAddr("owner");
    address launcher = makeAddr("launcher");
    address buyer = makeAddr("buyer");

    PotVault pot;
    JIGLaunch launch;
    JIG jig;

    function setUp() public {
        vm.createSelectFork("sepolia");
        pot = new PotVault(owner);
        launch = new JIGLaunch(POSM, PERMIT2, launcher, address(pot));
        jig = new JIG(address(launch), address(pot));
        vm.prank(launcher);
        launch.setJig(address(jig));
    }

    function test_launch_seeds_single_sided_and_locks() public {
        assertEq(jig.balanceOf(address(launch)), 900_000_000e18);

        vm.prank(launcher);
        uint256 id = launch.launch(FEE, TICK_SPACING, address(0), SQRT_PRICE, TICK_LOWER, TICK_UPPER);

        assertTrue(launch.launched());
        assertEq(launch.tokenId(), id);
        assertEq(IERC721(POSM).ownerOf(id), address(launch), "LP NFT held by the launch contract");
        assertLt(jig.balanceOf(address(launch)), 1e18, "all JIG seeded (dust only)");
        assertEq(address(launch).balance, 0, "no ETH needed");

        (uint160 sqrtP, int24 tick,,) = IPoolManager(POOL_MANAGER).getSlot0(_key().toId());
        assertEq(sqrtP, SQRT_PRICE);
        assertGe(tick, TICK_UPPER);

        vm.prank(launcher);
        vm.expectRevert(JIGLaunch.AlreadyLaunched.selector);
        launch.launch(FEE, TICK_SPACING, address(0), SQRT_PRICE, TICK_LOWER, TICK_UPPER);
    }

    function test_range_must_sit_below_price() public {
        vm.prank(launcher);
        vm.expectRevert(JIGLaunch.RangeNotBelowPrice.selector);
        launch.launch(FEE, TICK_SPACING, address(0), SQRT_PRICE, 154_400, 160_000);
    }

    function test_only_launcher() public {
        vm.prank(buyer);
        vm.expectRevert(JIGLaunch.NotLauncher.selector);
        launch.launch(FEE, TICK_SPACING, address(0), SQRT_PRICE, TICK_LOWER, TICK_UPPER);
    }

    function test_buy_with_eth_then_fees_go_to_pot() public {
        vm.prank(launcher);
        launch.launch(FEE, TICK_SPACING, address(0), SQRT_PRICE, TICK_LOWER, TICK_UPPER);

        PoolSwapTest swapper = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        swapper.swap{value: 1 ether}(
            _key(),
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 got = jig.balanceOf(buyer);
        assertGt(got, 4_000_000e18, "about 5M JIG for 1 ETH minus fee and slippage");
        assertLt(got, 5_000_000e18);

        uint256 potBefore = address(pot).balance;
        launch.collectFees();
        uint256 feeEth = address(pot).balance - potBefore;
        assertApproxEqRel(feeEth, 0.01 ether, 0.01e18, "1% of 1 ETH to the pot");
        assertEq(IERC721(POSM).ownerOf(launch.tokenId()), address(launch), "position still locked");
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(jig)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }
}
