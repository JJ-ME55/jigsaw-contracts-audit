// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JIG} from "../src/JIG.sol";
import {PotVault} from "../src/PotVault.sol";
import {Vesting} from "../src/Vesting.sol";
import {CreatorFeeHook} from "../src/CreatorFeeHook.sol";
import {CoinFactory} from "../src/CoinFactory.sol";
import {AirdropClaim} from "../src/AirdropClaim.sol";
import {CreatorCoin} from "../src/CreatorCoin.sol";

contract OwnedCollection {
    address public owner;
    constructor(address o) { owner = o; }
}
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Runs against a Sepolia fork: forge test --match-contract CreatorCoinFork --fork-url sepolia
contract CreatorCoinForkTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant POSM = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address owner = makeAddr("owner");
    address platform = makeAddr("platform");
    address creator = makeAddr("creator");
    address collection;
    address flywheel = makeAddr("flywheel");
    address buyer = makeAddr("buyer");

    PotVault pot;
    JIG jig;
    CreatorFeeHook hook;
    CoinFactory factory;
    AirdropClaim airdrop;
    PoolSwapTest swapper;
    CreatorCoin coin;
    PoolKey key;
    bool coinIs0;

    // 1 JIG = 1,000 coin at launch (coin per JIG), full range on the coin side
    uint256 constant COIN_PER_JIG = 1000;

    function setUp() public {
        vm.createSelectFork("sepolia");
        pot = new PotVault(owner);
        address launchStub = makeAddr("launchStub"); // JIG's 90% goes here; we hand it out as test money
        jig = new JIG(launchStub, address(pot));

        collection = address(new OwnedCollection(creator));
        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) | (uint160(0xBEEF) << 20));
        deployCodeTo(
            "CreatorFeeHook.sol:CreatorFeeHook",
            abi.encode(POOL_MANAGER, address(jig), owner, platform, address(pot)),
            hookAddr
        );
        hook = CreatorFeeHook(hookAddr);
        airdrop = new AirdropClaim(platform, address(pot));
        factory = new CoinFactory(POSM, PERMIT2, hookAddr, address(jig), platform, address(airdrop), 0.01 ether);
        vm.prank(platform);
        airdrop.setFactory(address(factory));
        vm.prank(owner);
        hook.setFactory(address(factory));

        swapper = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        vm.deal(creator, 1 ether);
        vm.deal(buyer, 1 ether);
        vm.prank(launchStub);
        jig.transfer(buyer, 10_000_000e18);
    }

    function _launch(uint24 feePips) internal {
        // Decide ordering first: coin address is unknown until deployed, so launch with a price computed for both cases.
        // The address the factory will give the coin: CREATE2 with the collection-bound salt.
        address predictedCoin = factory.predictCoin(collection, "Cool", "COOL", bytes32(bytes20(collection)));
        coinIs0 = predictedCoin < address(jig);
        // price = currency1 per currency0
        uint256 price = coinIs0 ? 1e18 / COIN_PER_JIG : COIN_PER_JIG * 1e18; // scaled by 1e18 for sqrt
        uint160 sqrtP = uint160((_sqrt(price) * (1 << 96)) / 1e9);
        int24 startTick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 lower; int24 upper;
        if (coinIs0) { lower = (startTick / 200 + 1) * 200; upper = 887_200; }
        else { lower = -887_200; upper = (startTick / 200 - 1) * 200; }

        vm.prank(creator);
        (, address coinAddr) = factory.launch{value: 0.01 ether}(_params(collection, feePips, flywheel, sqrtP, lower, upper));
        coin = CreatorCoin(coinAddr);
        assertEq(coinAddr, predictedCoin);
        key = factory.poolKeyOf(0);
    }

    function _buy(address who, uint256 jigIn, bytes memory hookData) internal returns (uint256 got) {
        uint256 before = coin.balanceOf(who);
        vm.startPrank(who);
        jig.approve(address(swapper), jigIn);
        swapper.swap(
            key,
            SwapParams({zeroForOne: !coinIs0, amountSpecified: -int256(jigIn), sqrtPriceLimitX96: !coinIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();
        got = coin.balanceOf(who) - before;
    }

    function _sell(address who, uint256 coinIn, bytes memory hookData) internal returns (uint256 got) {
        uint256 before = jig.balanceOf(who);
        vm.startPrank(who);
        coin.approve(address(swapper), coinIn);
        swapper.swap(
            key,
            SwapParams({zeroForOne: coinIs0, amountSpecified: -int256(coinIn), sqrtPriceLimitX96: coinIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();
        got = jig.balanceOf(who) - before;
    }

    function test_launch_distributes_supply_and_locks_lp() public {
        _launch(10_000);
        assertEq(coin.totalSupply(), 1_000_000_000e18);
        assertEq(coin.balanceOf(address(airdrop)), 50_000_000e18, "airdrop share delivered to AirdropClaim");
        assertEq(coin.balanceOf(creator), 0, "no creator allocation unless asked");
        assertLt(coin.balanceOf(address(factory)), 1e18, "pool share seeded");
        (,,, uint256 tokenId,) = factory.launches(0);
        assertEq(IERC721(POSM).ownerOf(tokenId), address(factory), "LP locked in the factory");
        assertEq(platform.balance, 0.01 ether, "launch fee to platform");
        assertEq(factory.coinOf(collection), address(coin));
        vm.prank(creator);
        vm.expectRevert(CoinFactory.CollectionHasCoin.selector);
        factory.launch{value: 0.01 ether}(_params(collection, 10_000, address(0), 1, 0, 1));
    }

    function test_buy_during_snipe_window_pays_60pct_then_decays() public {
        _launch(10_000);
        PoolId id = key.toId();
        (,,,,,,,, uint64 launchedAt,,,) = hook.pools(id);
        assertEq(hook.currentFee(id), 600_000);
        vm.warp(launchedAt + 5 seconds);
        assertApproxEqAbs(hook.currentFee(id), 305_000, 1000);
        vm.warp(launchedAt + 10 seconds);
        assertEq(hook.currentFee(id), 10_000);
    }

    function test_buy_fee_taken_in_coin_converted_to_jig_and_split() public {
        _launch(10_000);
        vm.warp(block.timestamp + 10 seconds);
        uint256 potBefore = hook.claimable(address(pot));
        uint256 got = _buy(buyer, 1_000e18, "");
        assertGt(got, 0);
        uint256 total = hook.totalClaimable();
        assertGt(total, 0, "fee converted to JIG and credited");
        assertEq(coin.balanceOf(address(hook)), 0, "hook holds no coin");
        assertEq(hook.heldJig(), total, "hook holds exactly the claimable JIG as claims");
        // split at 1%: platform 25, pot 3, deepening 2 (pot here), flywheel 20 (default), creator 50
        assertApproxEqAbs(hook.claimable(flywheel), total * 2000 / 10_000, 4, "flywheel takes the rounding remainder");
        assertApproxEqAbs(hook.claimable(address(pot)) - potBefore, total * 500 / 10_000, 2, "pot 3% + deepening 2% (pot stands in)");
        assertEq(hook.claimable(platform), total * 2500 / 10_000);
        assertApproxEqAbs(hook.claimable(creator), total * 5000 / 10_000, 8, "creator 50% at a 1% fee by default");
        // about 1% of the JIG in: buy of 1000 JIG, fee taken on the coin side then sold back, so a bit under 10 JIG
        assertApproxEqRel(total, 10e18, 0.15e18);
    }

    function test_sell_fee_taken_in_jig_directly() public {
        _launch(10_000);
        vm.warp(block.timestamp + 10 seconds);
        uint256 got = _buy(buyer, 1_000e18, "");
        uint256 before = hook.totalClaimable();
        uint256 jigOut = _sell(buyer, got / 2, "");
        uint256 fee = hook.totalClaimable() - before;
        assertApproxEqRel(fee, jigOut / 99, 0.02e18, "1% of the JIG output");
    }

    function test_platform_band_at_1pct() public {
        _launch(10_000);
        vm.warp(block.timestamp + 10 seconds);
        _buy(buyer, 1_000e18, "");
        uint256 total = hook.totalClaimable();
        assertApproxEqAbs(hook.claimable(platform), total * 2500 / 10_000, 2);
    }

    function test_band_at_5pct() public {
        _launch(50_000);
        vm.warp(block.timestamp + 10 seconds);
        _buy(buyer, 1_000e18, "");
        uint256 total = hook.totalClaimable();
        assertApproxEqAbs(hook.claimable(platform), total * 3500 / 10_000, 2, "platform 35% band at 5%");
        assertApproxEqAbs(hook.claimable(creator), total * 4000 / 10_000, 8, "creator 40% at 5% (block 60 minus flywheel 20)");
        assertApproxEqRel(total, 50e18, 0.15e18, "about 5% of 1000 JIG");
    }

    function test_claim_is_pull() public {
        _launch(10_000);
        vm.warp(block.timestamp + 10 seconds);
        _buy(buyer, 1_000e18, "");
        uint256 owed = hook.claimable(creator);
        vm.prank(creator);
        uint256 paid = hook.claim();
        assertEq(paid, owed);
        assertEq(jig.balanceOf(creator), owed);
        assertEq(hook.claimable(creator), 0);
    }

    function test_creator_slider_and_recycle() public {
        _launch(10_000);
        vm.warp(block.timestamp + 10 seconds);
        vm.prank(creator);
        hook.setCreatorShare(key, 7000); // whole block to the creator, nothing to the flywheel
        _buy(buyer, 1_000e18, "");
        uint256 total = hook.totalClaimable();
        assertApproxEqAbs(hook.claimable(creator), total * 7000 / 10_000, 8);
        assertLe(hook.claimable(flywheel), 4, "only rounding dust to the flywheel");
        vm.prank(creator);
        vm.expectRevert(CreatorFeeHook.BadShare.selector);
        hook.setCreatorShare(key, 7001);
        // unclaimed for 7 days: anyone folds it back through the split
        vm.expectRevert(CreatorFeeHook.NotStale.selector);
        hook.recycle(key, creator);
        vm.warp(block.timestamp + 8 days); // grace is 7 to 8 days by day bucket (round 5)
        uint256 stale = hook.claimable(creator);
        hook.recycle(key, creator);
        assertEq(hook.claimable(creator), 0, "the creator who let it go stale gets nothing back");
        assertApproxEqAbs(hook.claimable(flywheel), stale * 7000 / 10_000, 8, "the block goes to the flywheel");
        assertGt(hook.claimable(platform), total * 2500 / 10_000, "platform grew from the recycle");
        assertEq(hook.totalClaimable(), total, "nothing created or lost");
    }

    function test_lower_fee_only_down_and_only_creator() public {
        _launch(50_000);
        vm.prank(buyer);
        vm.expectRevert(CreatorFeeHook.NotCreator.selector);
        hook.lowerFee(key, 10_000);
        vm.prank(creator);
        vm.expectRevert(CreatorFeeHook.BadFee.selector);
        hook.lowerFee(key, 60_000);
        vm.prank(creator);
        hook.lowerFee(key, 20_000);
        vm.warp(block.timestamp + 10 seconds);
        assertEq(hook.currentFee(key.toId()), 20_000);
    }

    function test_bad_fee_and_unregistered_pool_refused() public {
        vm.prank(creator);
        vm.expectRevert(CreatorFeeHook.BadFee.selector);
        factory.launch{value: 0.01 ether}(_params(collection, 15_000, address(0), 1 << 96, -200, 0));
    }


    function _params(address collection, uint24 feePips, address flywheel, uint160 sqrtP, int24 lower, int24 upper) internal pure returns (CoinFactory.LaunchParams memory) {
        return CoinFactory.LaunchParams({collection: collection, name: "Cool", symbol: "COOL", feePips: feePips, flywheel: flywheel, creatorShareBps: type(uint16).max, creatorBps: 0, devBuyJig: 0, devBuyMinCoin: 0, maxFeeWei: 0.01 ether, salt: bytes32(bytes20(collection)), sqrtPriceX96: sqrtP, tickLower: lower, tickUpper: upper});
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }
}
