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
        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) | (uint160(0xC0DE) << 20));
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
        return CoinFactory.LaunchParams({collection: collection, name: "Cool", symbol: "COOL", feePips: feePips, flywheel: flywheel, creatorShareBps: type(uint16).max, creatorBps: 0, devBuyJig: 0, devBuyMinCoin: 0, sqrtPriceX96: sqrtP, tickLower: lower, tickUpper: upper});
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
