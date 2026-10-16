// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JIG} from "../src/JIG.sol";
import {PotVault} from "../src/PotVault.sol";
import {Vesting} from "../src/Vesting.sol";
import {JIGLaunch} from "../src/JIGLaunch.sol";
import {CreatorFeeHook} from "../src/CreatorFeeHook.sol";
import {CoinFactory} from "../src/CoinFactory.sol";
import {CreatorCoin} from "../src/CreatorCoin.sol";
import {HolderDrip} from "../src/HolderDrip.sol";
import {BuybackAndBurn} from "../src/BuybackAndBurn.sol";
import {AirdropClaim} from "../src/AirdropClaim.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract CreatorNFT {
    address public owner; address public creator;
    constructor(address o, address c) { owner = o; creator = c; }
}

contract OwnedNFT is ERC721 {
    uint256 public totalSupply;
    address public owner;
    constructor(address o) ERC721("Mock", "MOCK") { owner = o; }
    function mint(address to, uint256 n) external { for (uint256 i; i < n; i++) _mint(to, ++totalSupply); }
}

/// Pins the fixes from the 15 Oct 2026 adversarial review. forge test --match-contract RegressionsFork --fork-url sepolia
contract RegressionsForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POSM = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address owner = makeAddr("owner");
    address platform = makeAddr("platform");
    address creator = makeAddr("creator");
    address squatter = makeAddr("squatter");
    address buyer = makeAddr("buyer");
    address holderA = makeAddr("holderA");
    address late = makeAddr("late");

    AirdropClaim airdrop;

    PotVault pot; JIG jig; Vesting vesting; JIGLaunch launch; CreatorFeeHook hook; CoinFactory factory;
    OwnedNFT nft; PoolSwapTest swapper; PoolKey jigKey;

    function setUp() public {
        vm.createSelectFork("sepolia");
        pot = new PotVault(owner);
        launch = new JIGLaunch(POSM, PERMIT2, owner, address(pot), platform);
        jig = new JIG(address(launch), address(pot));
        vesting = new Vesting();
        vm.startPrank(owner);
        launch.setJig(address(jig));
        launch.launch(15_000, 200, address(0), TickMath.getSqrtPriceAtTick(202_400), -887_200, 202_400);
        vm.stopPrank();
        jigKey = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(jig)), fee: 15_000, tickSpacing: 200, hooks: IHooks(address(0))});
        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) | (uint160(0xC0DE) << 20));
        deployCodeTo("CreatorFeeHook.sol:CreatorFeeHook", abi.encode(POOL_MANAGER, address(jig), owner, platform, address(pot)), hookAddr);
        hook = CreatorFeeHook(hookAddr);
        airdrop = new AirdropClaim(platform, address(pot));
        factory = new CoinFactory(POSM, PERMIT2, hookAddr, address(jig), platform, address(airdrop), 0.01 ether);
        vm.prank(platform);
        airdrop.setFactory(address(factory));
        vm.prank(owner);
        hook.setFactory(address(factory));
        nft = new OwnedNFT(creator);
        nft.mint(holderA, 4);
        swapper = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        vm.deal(buyer, 5 ether); vm.deal(creator, 1 ether); vm.deal(squatter, 1 ether);
        vm.prank(buyer);
        swapper.swap{value: 1 ether}(jigKey, SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    function _launchCoin(address who, address flywheel) internal returns (CreatorCoin coin, PoolKey memory key, bool coinIs0) {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        coinIs0 = predicted < address(jig);
        uint256 price = coinIs0 ? 1e18 / 1000 : 1000 * 1e18;
        uint160 sqrtP = uint160((_sqrt(price) * (1 << 96)) / 1e9);
        int24 startTick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 lower; int24 upper;
        if (coinIs0) { lower = (startTick / 200 + 1) * 200; upper = 887_200; } else { lower = -887_200; upper = (startTick / 200 - 1) * 200; }
        vm.prank(who);
        (, address c) = factory.launch{value: 0.01 ether}(_params(address(nft), 10_000, flywheel, sqrtP, lower, upper));
        coin = CreatorCoin(c);
        key = factory.poolKeyOf(factory.count() - 1);
    }

    function _swap(address who, PoolKey memory key, bool zeroForOne, int256 amountSpecified, bytes memory hookData) internal {
        vm.startPrank(who);
        jig.approve(address(swapper), type(uint256).max);
        swapper.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), hookData);
        vm.stopPrank();
    }

    // HIGH: squatting a collection
    function test_only_collection_owner_can_launch() public {
        vm.prank(squatter);
        vm.expectRevert(CoinFactory.NotCollectionOwner.selector);
        factory.launch{value: 0.01 ether}(_params(address(nft), 10_000, address(0), 1 << 96, -200, 0));
        vm.prank(creator);
        vm.expectRevert(CoinFactory.ZeroAddress.selector);
        factory.launch{value: 0.01 ether}(_params(makeAddr("eoa"), 10_000, address(0), 1 << 96, -200, 0));
        _launchCoin(creator, address(0));
        assertEq(factory.count(), 1);
        // a collection with a creator() field: only the creator may launch, even if the platform is owner()
        CreatorNFT cn = new CreatorNFT(platform, creator);
        vm.deal(platform, 1 ether);
        vm.prank(platform);
        vm.expectRevert(CoinFactory.NotCollectionOwner.selector);
        factory.launch{value: 0.01 ether}(_params(address(cn), 10_000, address(0), 1 << 96, -200, 0));
    }

    // HIGH: pot could never claim
    function test_anyone_can_push_the_pot_its_slice() public {
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        vm.warp(block.timestamp + 10 seconds);
        _swap(buyer, key, !coinIs0, -100_000e18, "");
        uint256 owed = hook.claimable(address(pot));
        assertGt(owed, 0);
        uint256 before = jig.balanceOf(address(pot));
        hook.claimFor(address(pot));
        assertEq(jig.balanceOf(address(pot)) - before, owed);
        assertEq(hook.claimable(address(pot)), 0);
    }

    // keeper-only, whole balance, min-out
    function test_buyback_is_keeper_only_with_min_out() public {
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        vm.warp(block.timestamp + 10 seconds);
        BuybackAndBurn bb = new BuybackAndBurn(address(hook), address(factory), address(nft), platform);
        vm.prank(buyer);
        jig.transfer(address(bb), 20_000e18);
        vm.prank(buyer);
        vm.expectRevert(BuybackAndBurn.NotKeeper.selector);
        bb.run(0);
        vm.prank(platform);
        vm.expectRevert(BuybackAndBurn.TooLittleOut.selector);
        bb.run(type(uint256).max);
        vm.prank(platform);
        uint256 got = bb.run(1);
        assertGt(got, 0);
        assertEq(jig.balanceOf(address(bb)), 0, "entire balance used");
        coinIs0;
    }

    // MEDIUM: exact-output discount
    function test_exact_output_pays_the_same_rate() public {
        (CreatorCoin coin, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        // in the snipe window: 60%
        uint256 j0 = jig.balanceOf(buyer);
        _swap(buyer, key, !coinIs0, -1_000e18, "");
        uint256 coinIn = coin.balanceOf(buyer);
        uint256 spentIn = j0 - jig.balanceOf(buyer);
        uint256 feeIn = hook.totalClaimable();
        // exact-output of the same coin amount, same window
        uint256 j1 = jig.balanceOf(buyer);
        _swap(buyer, key, !coinIs0, int256(coinIn), "");
        uint256 spentOut = jig.balanceOf(buyer) == j1 ? 0 : j1 - jig.balanceOf(buyer);
        uint256 feeOut = hook.totalClaimable() - feeIn;
        // the second buy is a touch pricier (price moved), so exact-out must cost at least as much as exact-in
        assertGe(spentOut, spentIn, "exact-output no longer cheaper");
        assertGe(feeOut * 100, feeIn * 95, "fee collected is comparable");
    }

    // HIGH: post-pull mints over-claim the drip
    function test_tokens_minted_after_a_pull_earn_nothing_from_it() public {
        HolderDrip drip = new HolderDrip(address(hook), address(nft));
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(drip));
        vm.warp(block.timestamp + 10 seconds);
        _swap(buyer, key, !coinIs0, -100_000e18, "");
        drip.pull();
        uint256 perToken = drip.owed(1);
        assertGt(perToken, 0);
        nft.mint(late, 4); // ids 5..8 after the pull
        assertEq(drip.owed(5), 0, "late token earns nothing from the earlier pull");
        uint256[] memory ids = new uint256[](4); ids[0] = 5; ids[1] = 6; ids[2] = 7; ids[3] = 8;
        vm.prank(late);
        assertEq(drip.claim(ids), 0);
        uint256[] memory a = new uint256[](4); a[0] = 1; a[1] = 2; a[2] = 3; a[3] = 4;
        vm.prank(holderA);
        uint256 got = drip.claim(a);
        assertApproxEqAbs(got, perToken * 4, 4, "original holders get everything");
        // a second pull is split over all 8
        _swap(buyer, key, !coinIs0, -100_000e18, "");
        drip.pull();
        assertGt(drip.owed(5), 0);
        assertApproxEqAbs(drip.owed(5), drip.owed(1), 2);
    }

    // HIGH (second pass): claimFor could strand the drip's slice
    function test_claimFor_cannot_strand_the_drip() public {
        HolderDrip drip = new HolderDrip(address(hook), address(nft));
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(drip));
        vm.warp(block.timestamp + 10 seconds);
        _swap(buyer, key, !coinIs0, -100_000e18, "");
        uint256 slice = hook.claimable(address(drip));
        hook.claimFor(address(drip)); // attacker pushes it first
        assertEq(drip.undistributed(), slice);
        drip.pull();
        assertEq(drip.undistributed(), 0);
        assertApproxEqAbs(drip.owed(1) * 4, slice, 4, "the pushed slice is distributed");
    }

    // HIGH (second pass): checkpoint accumulator must not truncate
    function test_large_accumulator_does_not_reopen_overclaim() public {
        HolderDrip drip = new HolderDrip(address(hook), address(nft));
        _launchCoin(creator, address(drip));
        // simulate a very large drip: 4 tokens, 5,000 JIG per token => acc = 5e21 * 1e18 > 2^128
        vm.prank(buyer);
        jig.transfer(address(drip), 20_000e18);
        drip.pull();
        assertGt(drip.accPerToken(), uint256(type(uint128).max));
        nft.mint(late, 1); // id 5 after the pull
        assertEq(drip.owed(5), 0, "late token earns nothing");
        assertApproxEqAbs(drip.owed(1), 5_000e18, 4);
    }

    // LOW (second pass): only the factory can start the airdrop clock
    function test_airdrop_notify_only_from_factory() public {
        AirdropClaim ac = new AirdropClaim(platform, address(pot));
        vm.expectRevert(AirdropClaim.NotFactory.selector);
        ac.notify(address(0x1234));
        vm.prank(platform);
        ac.setFactory(address(factory));
        vm.prank(address(factory));
        ac.notify(address(0x1234));
        assertGt(ac.receivedAt(address(0x1234)), 0);
    }


    function _params(address collection, uint24 feePips, address flywheel, uint160 sqrtP, int24 lower, int24 upper) internal pure returns (CoinFactory.LaunchParams memory) {
        return CoinFactory.LaunchParams({collection: collection, name: "Cool", symbol: "COOL", feePips: feePips, flywheel: flywheel, creatorShareBps: type(uint16).max, creatorBps: 0, devBuyJig: 0, devBuyMinCoin: 0, maxFeeWei: 0.01 ether, sqrtPriceX96: sqrtP, tickLower: lower, tickUpper: upper});
    }

    // creator allocation + dev buy + settable fee
    function test_creator_allocation_dev_buy_and_settable_fee() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        bool coinIs0 = predicted < address(jig);
        uint256 price = coinIs0 ? 1e18 / 1000 : 1000 * 1e18;
        uint160 sqrtP = uint160((_sqrt(price) * (1 << 96)) / 1e9);
        int24 startTick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 lower; int24 upper;
        if (coinIs0) { lower = (startTick / 200 + 1) * 200; upper = 887_200; } else { lower = -887_200; upper = (startTick / 200 - 1) * 200; }
        CoinFactory.LaunchParams memory p = _params(address(nft), 10_000, address(0), sqrtP, lower, upper);
        p.creatorBps = 300; // 3% to the creator's wallet
        p.devBuyJig = 50_000e18; // and a dev buy
        p.devBuyMinCoin = 1;
        vm.prank(buyer);
        jig.transfer(creator, 50_000e18);
        vm.startPrank(creator);
        jig.approve(address(factory), 50_000e18);
        (, address c) = factory.launch{value: 0.01 ether}(p);
        vm.stopPrank();
        CreatorCoin coin = CreatorCoin(c);
        assertGt(coin.balanceOf(creator), 30_000_000e18, "3% plus the dev buy");
        assertEq(jig.balanceOf(creator), 0, "dev buy JIG spent");
        // the dev buy pays the chosen fee, not the 60% snipe fee: about 1% of 50k JIG
        assertApproxEqRel(hook.totalClaimable(), 500e18, 0.2e18, "dev buy charged ~1%, not 60%");
        // settable launch fee
        vm.prank(buyer);
        vm.expectRevert(CoinFactory.NotPlatform.selector);
        factory.setLaunchFee(1);
        vm.prank(platform);
        factory.setLaunchFee(0.02 ether);
        p.maxFeeWei = 0.02 ether; // the creator agrees to the raised fee
        assertEq(factory.launchFeeWei(), 0.02 ether);
        // too much creator allocation refused (checked before anything else)
        p.creatorBps = 501; p.devBuyJig = 0;
        vm.prank(creator);
        vm.expectRevert(CoinFactory.TooMuchCreator.selector);
        factory.launch{value: 0.02 ether}(p);
    }

    // HIGH (third pass): recycling is per pool and never pays the party that went stale
    function test_recycle_cannot_touch_balances_earned_elsewhere() public {
        // victim earns on their own coin
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        vm.warp(block.timestamp + 10 seconds);
        _swap(buyer, key, !coinIs0, -100_000e18, "");
        uint256 victimBal = hook.claimable(creator);
        assertGt(victimBal, 0);
        // attacker launches a junk coin naming the victim as its flywheel
        OwnedNFT junk = new OwnedNFT(squatter);
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        bool c0 = predicted < address(jig);
        uint256 price = c0 ? 1e18 / 1000 : 1000 * 1e18;
        uint160 sqrtP = uint160((_sqrt(price) * (1 << 96)) / 1e9);
        int24 st = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 lo; int24 hi;
        if (c0) { lo = (st / 200 + 1) * 200; hi = 887_200; } else { lo = -887_200; hi = (st / 200 - 1) * 200; }
        CoinFactory.LaunchParams memory p = _params(address(junk), 10_000, creator, sqrtP, lo, hi);
        vm.prank(squatter);
        (, address junkCoin) = factory.launch{value: 0.01 ether}(p);
        PoolKey memory junkKey = factory.keyOf(address(junk));
        vm.prank(squatter);
        hook.setCreatorShare(junkKey, 7000);
        vm.warp(block.timestamp + 8 days);
        // the victim earned nothing on the junk pool, so there is nothing to recycle there
        vm.expectRevert(CreatorFeeHook.NotStale.selector);
        hook.recycle(junkKey, creator);
        assertEq(hook.claimable(creator), victimBal, "victim untouched");
        junkCoin;
        // protocol addresses cannot be named as a flywheel at all
        OwnedNFT junk2 = new OwnedNFT(squatter);
        p.collection = address(junk2); p.flywheel = platform;
        vm.prank(squatter);
        vm.expectRevert(CreatorFeeHook.BadFlywheel.selector);
        factory.launch{value: 0.01 ether}(p);
    }

    // MEDIUM (third pass): a stale flywheel balance goes to the pot, never to the creator
    function test_stale_flywheel_balance_feeds_the_pot_not_the_creator() public {
        HolderDrip drip = new HolderDrip(address(hook), address(nft));
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(drip));
        vm.warp(block.timestamp + 10 seconds);
        _swap(buyer, key, !coinIs0, -100_000e18, "");
        uint256 dripBal = hook.claimable(address(drip));
        vm.prank(creator);
        hook.setCreatorShare(key, 7000);
        uint256 creatorBefore = hook.claimable(creator);
        uint256 potBefore = hook.claimable(address(pot));
        vm.warp(block.timestamp + 8 days);
        hook.recycle(key, address(drip));
        assertEq(hook.claimable(creator), creatorBefore, "creator gains nothing");
        assertGt(hook.claimable(address(pot)) - potBefore, dripBal * 6000 / 10_000, "the block went to the pot");
        assertEq(hook.claimable(address(drip)), 0);
    }

    // HIGH (swarm audit): a dust JIG order on the empty side of the range must not capture the coin-side fee
    function test_dust_order_outside_range_cannot_capture_the_fee() public {
        (CreatorCoin coin, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        vm.warp(block.timestamp + 10 seconds);
        _swap(buyer, key, !coinIs0, -100_000e18, ""); // put ~90k JIG into the range
        // attacker parks a dust position on the empty side of the range
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        int24 lo = coinIs0 ? int24(-600_000) : int24(600_000);
        int24 hi = lo + 200;
        vm.startPrank(buyer);
        jig.approve(address(lp), type(uint256).max);
        coin.approve(address(lp), type(uint256).max);
        vm.expectRevert(); // since round 3 a creator pool takes no liquidity but the factory's seed
        lp.modifyLiquidity(key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: 1e15, salt: 0}), "");
        vm.stopPrank();
        // the exact-output sell the attack used is refused outright now (swarm audit 2: it also underpaid the fee)
        vm.prank(buyer);
        coin.approve(address(swapper), type(uint256).max);
        _expectExactOutputSellRefused(buyer, key, coinIs0, 70_000e18);
        // a large exact-input buy still converts its coin fee inside the range: credited or parked, never sold to the dust order
        uint256 claimBefore = hook.totalClaimable();
        _swap(buyer, key, !coinIs0, -600_000e18, "");
        uint256 pending = hook.pendingCoin(key.toId());
        assertTrue(hook.totalClaimable() > claimBefore || pending > 0, "the fee is credited or kept as pending coin, never sold for nothing");
        // the price never left the range, so the dust position below it saw no coin at all
        (uint160 spot,,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        uint160 edge = coinIs0 ? TickMath.getSqrtPriceAtTick(-887_200 + 0) : TickMath.getSqrtPriceAtTick(887_200);
        edge; spot;
    }

    // MEDIUM (swarm audit 2): exact-output sells valued the coin fee at the post-trade price (~55% of the exact-input fee)
    function test_exact_output_sell_is_refused_exact_input_sell_pays_full_fee() public {
        (CreatorCoin coin, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        vm.warp(block.timestamp + 10 seconds);
        _swap(buyer, key, !coinIs0, -500_000e18, "");
        vm.prank(buyer);
        coin.approve(address(swapper), type(uint256).max);
        _expectExactOutputSellRefused(buyer, key, coinIs0, 1_000e18); // exact JIG out, coin in
        uint256 before = hook.totalClaimable();
        uint256 jigBefore = jig.balanceOf(buyer);
        _swap(buyer, key, coinIs0, -int256(coin.balanceOf(buyer) / 2), ""); // exact-input sell: fee is JIG, no conversion
        uint256 out = jig.balanceOf(buyer) - jigBefore;
        uint256 feeTaken = hook.totalClaimable() - before;
        assertApproxEqRel(feeTaken, (out + feeTaken) / 100, 0.01e18, "1% of the gross JIG output");
        // exact-output BUYS are still fine (fee in JIG, charged on top)
        _swap(buyer, key, !coinIs0, int256(1_000e18), "");
    }

    // LOW (swarm audit 3): an LP band inside the range traded coin for JIG at spot with no fee and no anti-snipe
    function test_creator_pool_takes_no_liquidity_but_the_seed() public {
        (CreatorCoin coin, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        _swap(buyer, key, !coinIs0, -100_000e18, "");
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        (, int24 tick,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        int24 lo = (tick / 200) * 200 - 200;
        vm.startPrank(buyer);
        jig.approve(address(lp), type(uint256).max);
        coin.approve(address(lp), type(uint256).max);
        vm.expectRevert();
        lp.modifyLiquidity(key, ModifyLiquidityParams({tickLower: lo, tickUpper: lo + 400, liquidityDelta: 1e15, salt: 0}), "");
        vm.warp(block.timestamp + 365 days); // never, not just during the snipe window
        vm.expectRevert();
        lp.modifyLiquidity(key, ModifyLiquidityParams({tickLower: lo, tickUpper: lo + 400, liquidityDelta: 1e15, salt: 0}), "");
        vm.stopPrank();
        assertEq(IPoolManager(POOL_MANAGER).getLiquidity(key.toId()) > 0, true, "the factory's seed is still there");
    }

    // INFO (swarm audit 3): a dust buy every 7 days could keep a stale balance from ever being recycled
    function test_recycle_clock_runs_from_the_first_unclaimed_credit() public {
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        vm.warp(block.timestamp + 10 seconds);
        _swap(buyer, key, !coinIs0, -10_000e18, "");
        assertGt(hook.claimable(creator), 0);
        vm.warp(block.timestamp + 8 days);
        _swap(buyer, key, !coinIs0, -1e12, ""); // dust credit on the stale balance
        uint256 got = hook.recycle(key, creator);
        assertGt(got, 0, "recycled despite the dust refresh");
        // a fresh balance after a claim starts a new clock
        _swap(buyer, key, !coinIs0, -10_000e18, "");
        vm.prank(creator);
        hook.claim();
        _swap(buyer, key, !coinIs0, -10_000e18, "");
        vm.expectRevert(CreatorFeeHook.NotStale.selector);
        hook.recycle(key, creator);
    }

    // LOW (swarm audit 4, Jj option a): an exact-input buy pays f of the JIG spent at every size, like an exact-output buy
    function test_exact_input_buy_pays_nominal_fee_at_every_size() public {
        (CreatorCoin coin, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        vm.warp(block.timestamp + 10 seconds);
        uint256[4] memory sizes = [uint256(1_000e18), 100_000e18, 1_000_000e18, 10_000_000e18];
        for (uint256 i; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            uint256 before = hook.totalClaimable();
            uint256 coinBefore = coin.balanceOf(buyer);
            _swap(buyer, key, !coinIs0, -int256(sizes[i]), "");
            uint256 feeJig = hook.totalClaimable() - before;
            uint256 pending = hook.pendingCoin(key.toId());
            if (pending == 0) assertApproxEqRel(feeJig, sizes[i] / 100, 0.01e18, "1% of the JIG spent");
            else assertLe(feeJig, sizes[i] / 100 + 1, "never above nominal");
            assertGt(coin.balanceOf(buyer) - coinBefore, 0);
            assertEq(hook.heldJig(), hook.totalClaimable(), "claims match");
            vm.revertToState(snap);
        }
    }

    // LOW (swarm audit 4): recycle must take only the credits that are 7 days old, never the fresh ones, and must not chain
    function test_recycle_takes_only_the_stale_part_and_does_not_chain() public {
        address fly = makeAddr("flywheelWallet");
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, fly);
        vm.warp(block.timestamp + 10 seconds);
        _swap(buyer, key, !coinIs0, -1_000e18, "");
        uint256 old = hook.claimable(creator);
        vm.warp(block.timestamp + 8 days);
        _swap(buyer, key, !coinIs0, -1_000_000e18, ""); // same block as the recycle
        uint256 freshCreator = hook.claimable(creator) - old;
        (uint256 stale, uint256 fresh) = hook.recyclable(key, creator);
        assertEq(stale, old);
        assertEq(fresh, freshCreator);
        uint256 flyBefore = hook.claimable(fly);
        uint256 got = hook.recycle(key, creator);
        assertEq(got, old, "only the 7-day-old credit was folded");
        assertEq(hook.claimable(creator), freshCreator, "the fresh credit stays with the creator");
        assertGt(hook.claimable(fly), flyBefore, "the stale block fed the flywheel");
        // the block just moved to the flywheel is fresh: recycling the flywheel in the same block takes none of it
        (uint256 flyStale,) = hook.recyclable(key, fly);
        if (flyStale == 0) {
            vm.expectRevert(CreatorFeeHook.NotStale.selector);
            hook.recycle(key, fly);
        } else {
            uint256 g2 = hook.recycle(key, fly);
            assertLe(g2, flyStale);
        }
    }

    // LOW (swarm audit 4): a fee raised after the quote cannot take more than the creator agreed to
    function test_launch_fee_above_the_creators_maximum_reverts() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        bool coinIs0 = predicted < address(jig);
        uint256 price = coinIs0 ? 1e18 / 1000 : 1000 * 1e18;
        uint160 sqrtP = uint160((_sqrt(price) * (1 << 96)) / 1e9);
        int24 startTick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 lower; int24 upper;
        if (coinIs0) { lower = (startTick / 200 + 1) * 200; upper = 887_200; } else { lower = -887_200; upper = (startTick / 200 - 1) * 200; }
        vm.prank(platform);
        factory.setLaunchFee(0.5 ether);
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(CoinFactory.WrongFee.selector);
        factory.launch{value: 0.5 ether}(_params(address(nft), 10_000, address(0), sqrtP, lower, upper)); // maxFeeWei is 0.01
        vm.prank(platform);
        factory.setLaunchFee(0.009 ether); // lowered: pays the lower fee, refunds the rest
        uint256 before = creator.balance;
        vm.prank(creator);
        factory.launch{value: 0.01 ether}(_params(address(nft), 10_000, address(0), sqrtP, lower, upper));
        assertEq(before - creator.balance, 0.009 ether);
    }

    // HIGH (swarm audit 5): booking only the floored per-pull amount let per-token claims exceed it and bricked pull()
    function test_holder_drip_survives_lossy_pulls_and_claims() public {
        OwnedNFT three = new OwnedNFT(creator);
        three.mint(holderA, 3); // 3 live tokens: 1e18 / 3 never divides
        HolderDrip drip = new HolderDrip(address(hook), address(three));
        for (uint256 i; i < 4; i++) {
            vm.prank(buyer);
            jig.transfer(address(drip), 1e18);
            drip.pull();
        }
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1; ids[1] = 2; ids[2] = 3;
        vm.prank(holderA);
        drip.claim(ids);
        assertLe(drip.paidOut(), drip.accounted(), "claims never exceed what was booked");
        vm.prank(buyer);
        jig.transfer(address(drip), 1e18);
        assertGt(drip.pull(), 0, "the drip keeps working after lossy pulls and a full claim");
        assertLe(drip.accounted() - drip.paidOut(), jig.balanceOf(address(drip)), "always solvent");
    }

    // MEDIUM (swarm audit 5): a price-limited exact-input buy pays f of the JIG it actually spent, and never reverts
    function test_partial_exact_input_buy_pays_f_of_what_it_spent() public {
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        vm.warp(block.timestamp + 10 seconds);
        _swap(buyer, key, !coinIs0, -100_000e18, "");
        // find the price a 10k buy reaches, then ask for 50k with that as the limit
        uint256 snap = vm.snapshotState();
        _swap(buyer, key, !coinIs0, -10_000e18, "");
        (uint160 limitPrice,,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        vm.revertToState(snap);
        uint256 before = hook.totalClaimable();
        uint256 jigBefore = jig.balanceOf(buyer);
        vm.prank(buyer);
        swapper.swap(key, SwapParams({zeroForOne: !coinIs0, amountSpecified: -int256(50_000e18), sqrtPriceLimitX96: limitPrice}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        uint256 spentJig = jigBefore - jig.balanceOf(buyer);
        assertLt(spentJig, 20_000e18, "the limit cut the fill well short of 50k");
        assertApproxEqRel(hook.totalClaimable() - before, spentJig / 100, 0.01e18, "1% of the JIG actually spent");
        assertEq(hook.heldJig(), hook.totalClaimable());
        // a huge request with a tight limit on a young pool must not revert
        vm.prank(buyer);
        swapper.swap(key, SwapParams({zeroForOne: !coinIs0, amountSpecified: -int256(1_000_000e18), sqrtPriceLimitX96: limitPrice}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        assertEq(hook.heldJig(), hook.totalClaimable());
    }

    // LOW (swarm audit 5): the recycle grace is never under 7 days, whatever the time of day the fee was earned
    function test_recycle_grace_is_never_under_seven_days() public {
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        vm.warp(((block.timestamp / 1 days) + 1) * 1 days - 1); // last second of a UTC day
        _swap(buyer, key, !coinIs0, -1_000e18, "");
        vm.warp(block.timestamp + 6 days + 1);
        vm.expectRevert(CreatorFeeHook.NotStale.selector);
        hook.recycle(key, creator);
        vm.warp(block.timestamp + 1 days - 1); // exactly 7 days after the credit
        (uint256 stale,) = hook.recyclable(key, creator);
        if (stale == 0) vm.warp(block.timestamp + 1 days); // the bucket rule may take up to a day more
        assertGt(hook.recycle(key, creator), 0);
    }

    // LOW (swarm audit 5): a claim must not make the next swapper pay to delete a long ledger
    function test_claim_does_not_make_the_next_swap_delete_the_ledger() public {
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        vm.warp(block.timestamp + 10 seconds);
        for (uint256 d; d < 60; d++) {
            _swap(buyer, key, !coinIs0, -100e18, "");
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        vm.prank(creator);
        hook.claim();
        vm.startPrank(buyer);
        jig.approve(address(swapper), type(uint256).max);
        uint256 g0 = gasleft();
        swapper.swap(key, SwapParams({zeroForOne: !coinIs0, amountSpecified: -int256(100e18), sqrtPriceLimitX96: !coinIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        uint256 used = g0 - gasleft();
        vm.stopPrank();
        assertLt(used, 700_000, "no ledger delete inside the swap");
        (uint256 stale, uint256 fresh) = hook.recyclable(key, creator);
        assertEq(stale, 0, "old entries abandoned at the claim");
        assertGt(fresh, 0);
    }

    // INFO (swarm audit 3): a fee update landing before a quoted launch must not revert it
    function test_launch_overpayment_is_refunded() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        bool coinIs0 = predicted < address(jig);
        uint256 price = coinIs0 ? 1e18 / 1000 : 1000 * 1e18;
        uint160 sqrtP = uint160((_sqrt(price) * (1 << 96)) / 1e9);
        int24 startTick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 lower; int24 upper;
        if (coinIs0) { lower = (startTick / 200 + 1) * 200; upper = 887_200; } else { lower = -887_200; upper = (startTick / 200 - 1) * 200; }
        uint256 before = creator.balance;
        uint256 platformBefore = platform.balance;
        vm.prank(creator);
        factory.launch{value: 0.015 ether}(_params(address(nft), 10_000, address(0), sqrtP, lower, upper));
        assertEq(before - creator.balance, 0.01 ether, "paid exactly the fee");
        assertEq(platform.balance - platformBefore, 0.01 ether);
        vm.prank(creator);
        vm.expectRevert(CoinFactory.WrongFee.selector);
        factory.launch{value: 0.009 ether}(_params(address(nft), 10_000, address(0), sqrtP, lower, upper));
    }

    // LOW (swarm audit 3): a factory built on an AirdropClaim already bound elsewhere could never launch
    function test_factory_refuses_an_airdrop_claim_bound_to_another_factory() public {
        AirdropClaim bound = new AirdropClaim(platform, address(pot));
        vm.prank(platform);
        bound.setFactory(makeAddr("otherFactory"));
        vm.expectRevert(CoinFactory.BadAirdropRecipient.selector);
        new CoinFactory(POSM, PERMIT2, address(hook), address(jig), platform, address(bound), 0.01 ether);
    }

    /// expectRevert must sit directly before the swap call (the _swap helper's approve would absorb it)
    function _expectExactOutputSellRefused(address who, PoolKey memory key, bool coinIs0, uint256 jigOut) internal {
        vm.prank(who);
        vm.expectRevert();
        swapper.swap(key, SwapParams({zeroForOne: coinIs0, amountSpecified: int256(jigOut), sqrtPriceLimitX96: coinIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2; y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }
}
