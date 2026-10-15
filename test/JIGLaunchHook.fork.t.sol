// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JIG} from "../src/JIG.sol";
import {PotVault} from "../src/PotVault.sol";
import {JIGLaunch} from "../src/JIGLaunch.sol";
import {JIGLaunchHook} from "../src/JIGLaunchHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// Runs against a Sepolia fork: forge test --match-contract Fork --fork-url sepolia
contract JIGLaunchHookForkTest is Test {
    address constant POSM = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    int24 constant TICK_SPACING = 200;
    int24 constant TICK_UPPER = 202_400;
    uint160 SQRT_PRICE = TickMath.getSqrtPriceAtTick(TICK_UPPER);
    int24 constant TICK_LOWER = -887_200;

    address owner = makeAddr("owner");
    address launcher = makeAddr("launcher");
    address friend = makeAddr("friend");
    address friend2 = makeAddr("friend2");
    address sniper = makeAddr("sniper");

    PotVault pot;
    JIGLaunch launch;
    JIG jig;
    JIGLaunchHook hook;
    PoolSwapTest swapper;
    bytes32 leafFriend;
    bytes32 leafFriend2;
    bytes32 root;

    function setUp() public {
        vm.createSelectFork("sepolia");
        pot = new PotVault(owner);
        launch = new JIGLaunch(POSM, PERMIT2, launcher, address(pot));
        jig = new JIG(address(launch), address(pot));
        vm.prank(launcher);
        launch.setJig(address(jig));

        // Put the hook at an address with exactly the right flag bits.
        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) | (uint160(0xABCD) << 20));
        deployCodeTo("JIGLaunchHook.sol:JIGLaunchHook", abi.encode(POOL_MANAGER, address(jig), launcher, address(launch), SQRT_PRICE, TICK_SPACING), hookAddr);
        hook = JIGLaunchHook(hookAddr);

        leafFriend = keccak256(bytes.concat(keccak256(abi.encode(friend))));
        leafFriend2 = keccak256(bytes.concat(keccak256(abi.encode(friend2))));
        root = leafFriend < leafFriend2 ? keccak256(abi.encodePacked(leafFriend, leafFriend2)) : keccak256(abi.encodePacked(leafFriend2, leafFriend));
        vm.prank(launcher);
        hook.setAllowlist(root);

        vm.prank(launcher);
        launch.launch(LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, hookAddr, SQRT_PRICE, TICK_LOWER, TICK_UPPER);

        swapper = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        vm.deal(friend, 10 ether);
        vm.deal(sniper, 10 ether);
        vm.deal(friend2, 10 ether);
    }

    function _proofFriend() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = leafFriend2;
    }

    function _buy(address who, uint256 eth, bytes memory hookData) internal returns (uint256 got) {
        uint256 before = jig.balanceOf(who);
        vm.prank(who, who); // msg.sender and tx.origin
        swapper.swap{value: eth}(
            _key(),
            SwapParams({zeroForOne: true, amountSpecified: -int256(eth), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        got = jig.balanceOf(who) - before;
    }

    function test_window_opened_on_init() public view {
        assertTrue(hook.initialized());
        assertEq(hook.windowEnd(), uint64(block.timestamp) + 10 minutes);
    }

    function test_friend_pays_1pct_sniper_pays_60pct() public {
        uint256 gotFriend = _buy(friend, 0.01 ether, abi.encode(_proofFriend()));
        uint256 gotSniper = _buy(sniper, 0.01 ether, abi.encode(_proofFriend())); // even with a friend's proof
        // Same size buys back to back at a $4k start move the price, so compare against the fee quotes.
        assertEq(hook.quoteFee(friend, _proofFriend()), 10_000);
        assertEq(hook.quoteFee(sniper, _proofFriend()), 600_000);
        assertLt(gotSniper * 100, gotFriend * 45, "sniper gets well under half as much JIG");
        assertGt(gotSniper, 0);
    }

    function test_no_proof_pays_60pct() public {
        uint256 got = _buy(friend, 0.01 ether, "");
        uint256 gotWithProof = _buy(friend2, 0.01 ether, abi.encode(_proofFriendFor2()));
        assertLt(got * 100, gotWithProof * 45);
    }

    function test_after_window_everyone_pays_1pct() public {
        vm.warp(block.timestamp + 10 minutes);
        assertEq(hook.quoteFee(sniper, _proofFriend()), 10_000);
        uint256 a = _buy(sniper, 0.01 ether, "");
        uint256 b = _buy(friend, 0.01 ether, abi.encode(_proofFriend()));
        // second buy is a touch pricier; within 15%
        assertApproxEqRel(a, b, 0.15e18);
    }

    function test_sniper_tax_fills_pot() public {
        _buy(sniper, 1 ether, "");
        uint256 before = address(pot).balance;
        launch.collectFees();
        assertApproxEqRel(address(pot).balance - before, 0.6 ether, 0.01e18, "60% of 1 ETH to the pot");
    }

    function test_allowlist_locked_after_init() public {
        vm.prank(launcher);
        vm.expectRevert(JIGLaunchHook.AlreadyInitialized.selector);
        hook.setAllowlist(bytes32(uint256(1)));
    }

    function test_nobody_else_can_initialise_or_front_run() public {
        // a fresh hook bound to this launch: a stranger cannot open the pool first
        address h2 = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) | (uint160(0xABCE) << 20));
        deployCodeTo("JIGLaunchHook.sol:JIGLaunchHook", abi.encode(POOL_MANAGER, address(jig), launcher, address(launch), SQRT_PRICE, TICK_SPACING), h2);
        PoolKey memory k = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(jig)), fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: TICK_SPACING, hooks: IHooks(h2)});
        vm.prank(sniper);
        vm.expectRevert();
        IPoolManager(POOL_MANAGER).initialize(k, SQRT_PRICE);
        assertFalse(JIGLaunchHook(h2).initialized());
    }

    function test_hook_refuses_other_pools() public {
        PoolKey memory other = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0x1234)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        IPoolManager(POOL_MANAGER).initialize(other, SQRT_PRICE);
    }

    function _proofFriendFor2() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = leafFriend;
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(jig)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }
}
