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
import {AirdropClaim} from "../src/AirdropClaim.sol";
import {SweepAndBurn} from "../src/SweepAndBurn.sol";
import {BuybackAndBurn} from "../src/BuybackAndBurn.sol";
import {LPDeepening} from "../src/LPDeepening.sol";
import {RewardsForwarder} from "../src/RewardsForwarder.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract MockNFT is ERC721 {
    uint256 public totalSupply;
    address public owner;
    constructor(address o) ERC721("Mock", "MOCK") { owner = o; }
    function mint(address to, uint256 n) external { for (uint256 i; i < n; i++) _mint(to, ++totalSupply); }
}

/// A one-listing marketplace: pays the seller, hands the NFT to the buyer.
/// A market whose fulfil pushes the module's pending hook slice into it mid-call (anyone can call claimFor).
contract PushingMarket {
    IERC721 public nft; address public seller; uint256 public tokenId; uint256 public price; CreatorFeeHook public hook;
    constructor(IERC721 nft_, address seller_, uint256 tokenId_, uint256 price_, CreatorFeeHook hook_) { nft = nft_; seller = seller_; tokenId = tokenId_; price = price_; hook = hook_; }
    function buy() external payable {
        require(msg.value == price, "price");
        hook.claimFor(msg.sender);
        nft.transferFrom(seller, msg.sender, tokenId);
        (bool ok,) = seller.call{value: msg.value}(""); require(ok);
    }
}

contract MockMarket {
    IERC721 public nft; address public seller; uint256 public tokenId; uint256 public price;
    constructor(IERC721 nft_, address seller_, uint256 tokenId_, uint256 price_) { nft = nft_; seller = seller_; tokenId = tokenId_; price = price_; }
    function buy() external payable {
        require(msg.value == price, "price");
        nft.transferFrom(seller, msg.sender, tokenId);
        (bool ok,) = seller.call{value: msg.value}(""); require(ok);
    }
}

/// forge test --match-contract FlywheelsFork --fork-url sepolia
contract FlywheelsForkTest is Test {
    address constant POSM = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address owner = makeAddr("owner");
    address platform = makeAddr("platform");
    address creator = makeAddr("creator");
    address buyer = makeAddr("buyer");
    address holderA = makeAddr("holderA");
    address holderB = makeAddr("holderB");
    address seller = makeAddr("seller");

    PotVault pot; JIG jig; Vesting vesting; JIGLaunch launch; CreatorFeeHook hook; CoinFactory factory;
    AirdropClaim airdrop; MockNFT nft; PoolSwapTest swapper; PoolKey jigKey;

    /// JIG's address decides which side of every coin pool it sits on; the low-address variants override this.
    function _deployJig(address l, address p) internal virtual returns (JIG) {
        return new JIG(l, p);
    }

    function setUp() public {
        vm.createSelectFork("sepolia");
        pot = new PotVault(owner);
        launch = new JIGLaunch(POSM, PERMIT2, owner, address(pot), platform);
        jig = _deployJig(address(launch), address(pot));
        vesting = new Vesting();
        vm.startPrank(owner);
        launch.setJig(address(jig));
        // hookless JIG/ETH pool, 1%, $4k start, full range
        launch.launch(15_000, 200, address(0), TickMath.getSqrtPriceAtTick(202_400), -887_200, 202_400);
        vm.stopPrank();
        jigKey = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(jig)), fee: 15_000, tickSpacing: 200, hooks: IHooks(address(0))});

        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) | (uint160(0xF1F1) << 20));
        deployCodeTo("CreatorFeeHook.sol:CreatorFeeHook", abi.encode(POOL_MANAGER, address(jig), owner, platform, address(pot)), hookAddr);
        hook = CreatorFeeHook(hookAddr);
        airdrop = new AirdropClaim(platform, address(pot));
        factory = new CoinFactory(POSM, PERMIT2, hookAddr, address(jig), platform, address(airdrop), 0.01 ether);
        vm.prank(owner);
        hook.setFactory(address(factory));
        vm.prank(platform);
        airdrop.setFactory(address(factory));

        nft = new MockNFT(creator);
        nft.mint(holderA, 3);
        nft.mint(holderB, 1);
        nft.mint(seller, 1); // token 5, the listing

        swapper = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        // buyer gets JIG by buying it with ETH
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        swapper.swap{value: 1 ether}(jigKey, SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        vm.deal(creator, 1 ether);
    }

    function _launchCoin(address flywheel) internal returns (CreatorCoin coin, PoolKey memory key, bool coinIs0) {
        address predicted = factory.predictCoin(address(nft), "Cool", "COOL", bytes32(bytes20(address(nft))));
        coinIs0 = predicted < address(jig);
        uint256 price = coinIs0 ? 1e18 / 1000 : 1000 * 1e18;
        uint160 sqrtP = uint160((_sqrt(price) * (1 << 96)) / 1e9);
        int24 startTick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 lower; int24 upper;
        if (coinIs0) { lower = (startTick / 200 + 1) * 200; upper = 887_200; } else { lower = -887_200; upper = (startTick / 200 - 1) * 200; }
        vm.prank(creator);
        (, address c) = factory.launch{value: 0.01 ether}(_params(address(nft), 10_000, flywheel, sqrtP, lower, upper));
        coin = CreatorCoin(c);
        key = factory.poolKeyOf(factory.count() - 1);
        vm.warp(block.timestamp + 10 seconds); // past the snipe window
    }

    function _buyCoin(PoolKey memory key, bool coinIs0, uint256 jigIn) internal {
        vm.startPrank(buyer);
        jig.approve(address(swapper), jigIn);
        swapper.swap(key, SwapParams({zeroForOne: !coinIs0, amountSpecified: -int256(jigIn), sqrtPriceLimitX96: !coinIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        vm.stopPrank();
    }

    // ---------- HolderDrip ----------

    function test_holder_drip_pays_per_token() public {
        HolderDrip drip = new HolderDrip(address(hook), address(nft));
        (, PoolKey memory key, bool coinIs0) = _launchCoin(address(drip));
        _buyCoin(key, coinIs0, 100_000e18);
        uint256 slice = hook.claimable(address(drip));
        assertGt(slice, 0);
        drip.pull();
        assertEq(jig.balanceOf(address(drip)), slice);
        assertEq(drip.undistributed(), 0);
        // 5 tokens: A has 3, B has 1, seller 1
        assertApproxEqAbs(drip.owed(1), slice / 5, 5);
        uint256[] memory a = new uint256[](3); a[0] = 1; a[1] = 2; a[2] = 3;
        vm.prank(holderA);
        uint256 got = drip.claim(a);
        assertApproxEqAbs(got, slice * 3 / 5, 15);
        assertEq(jig.balanceOf(holderA), got);
        vm.prank(holderA);
        assertEq(drip.claim(a), 0, "nothing twice");
        uint256[] memory b = new uint256[](1); b[0] = 1;
        vm.prank(holderB);
        vm.expectRevert(HolderDrip.NotOwner.selector);
        drip.claim(b);
    }

    // ---------- AirdropClaim ----------

    // per-NFT, on chain (Jj, 17 Oct): no root, no key; MockNFT has no maxSupply, so its 5 minted ids share the 5%
    function test_airdrop_claim_per_nft_and_sweep() public {
        (CreatorCoin coin,,) = _launchCoin(address(0));
        assertEq(coin.balanceOf(address(airdrop)), 50_000_000e18, "5% parked in AirdropClaim");
        (, , uint256 perNft, uint256 maxId) = airdrop.drops(address(coin));
        assertEq(maxId, 5); assertEq(perNft, 10_000_000e18);
        uint256[] memory a = new uint256[](3); a[0] = 1; a[1] = 2; a[2] = 3;
        vm.prank(holderA); airdrop.claim(address(coin), a);
        assertEq(coin.balanceOf(holderA), 30_000_000e18, "one share per NFT held");
        vm.prank(holderA); vm.expectRevert(AirdropClaim.AlreadyClaimed.selector); airdrop.claim(address(coin), a);
        uint256[] memory one = new uint256[](1); one[0] = 5; // the seller's, unclaimed
        vm.prank(holderB); vm.expectRevert(abi.encodeWithSelector(AirdropClaim.NotOwnerOf.selector, 5)); airdrop.claim(address(coin), one);
        one[0] = 6;
        vm.prank(holderB); vm.expectRevert(abi.encodeWithSelector(AirdropClaim.BadId.selector, 6)); airdrop.claim(address(coin), one);
        vm.expectRevert(AirdropClaim.NotExpired.selector); airdrop.sweep(address(coin));
        vm.warp(block.timestamp + 31 days);
        one[0] = 4;
        vm.prank(holderB); vm.expectRevert(AirdropClaim.Expired.selector); airdrop.claim(address(coin), one);
        airdrop.sweep(address(coin));
        assertEq(coin.balanceOf(address(pot)), 20_000_000e18, "unclaimed shares (ids 4 and 5) go to the pot");
    }

    // push airdrop (Jj, 17 Oct): anyone (the keeper) sends each id's share to the NFT's current owner; ids already
    // claimed, unminted or burned are skipped, so a batch never fails on a race with a manual claim
    function test_airdrop_push_sends_each_share_to_the_current_owner() public {
        (CreatorCoin coin,,) = _launchCoin(address(0));
        uint256[] memory one = new uint256[](1); one[0] = 4;
        vm.prank(holderB); airdrop.claim(address(coin), one); // holderB claims id 4 by hand first
        vm.prank(seller); IERC721(address(nft)).transferFrom(seller, address(0xdEaD), 5); // id 5 burned
        uint256[] memory all = new uint256[](7); for (uint256 i; i < 7; i++) all[i] = i + 1; // 6 and 7 do not exist
        vm.prank(buyer); uint256 sent = airdrop.claimFor(address(coin), all);
        assertEq(sent, 30_000_000e18, "ids 1-3 pushed; 4 claimed, 5 burned, 6-7 unminted are skipped");
        assertEq(coin.balanceOf(holderA), 30_000_000e18, "pushed to the owner, not the caller");
        assertEq(coin.balanceOf(holderB), 10_000_000e18);
        assertEq(coin.balanceOf(buyer), 0, "the caller gets nothing");
        assertEq(airdrop.claimFor(address(coin), all), 0, "a second push sends nothing");
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(AirdropClaim.Expired.selector); airdrop.claimFor(address(coin), all);
        airdrop.sweep(address(coin));
        assertEq(coin.balanceOf(address(pot)), 10_000_000e18, "the burned id's share goes to the pot");
    }

    // ---------- SweepAndBurn ----------

    function test_sweep_and_burn_buys_and_burns() public {
        SweepAndBurn sab = new SweepAndBurn(address(hook), address(nft), creator, platform, jigKey, 1e12);
        (, PoolKey memory key, bool coinIs0) = _launchCoin(address(sab));
        _buyCoin(key, coinIs0, 500_000e18);
        sab.pull();
        uint256 budget = jig.balanceOf(address(sab));
        assertGt(budget, 0);

        MockMarket market = new MockMarket(IERC721(address(nft)), seller, 5, 1e10); // the module's JIG is small at a $4k start
        vm.prank(seller);
        nft.setApprovalForAll(address(market), true);
        vm.prank(creator);
        sab.setMarket(address(market), true);

        // sell all of the module's JIG for ETH, buy token 5, burn it; the price reference comes from an earlier block
        vm.prank(platform);
        vm.expectRevert(SweepAndBurn.TooLittleOut.selector);
        sab.sweep(address(market), abi.encodeCall(MockMarket.buy, ()), 5, 1e10, budget, type(uint256).max);
        vm.prank(platform);
        sab.sweep(address(market), abi.encodeCall(MockMarket.buy, ()), 5, 1e10, budget, 1e10);
        assertEq(nft.ownerOf(5), sab.DEAD(), "burned");
        assertEq(sab.burned(), 1);
        assertEq(seller.balance, 1e10);

        vm.prank(buyer);
        vm.expectRevert(SweepAndBurn.NotSweeper.selector);
        sab.sweep(address(market), "", 5, 1, 1, 0);
        vm.prank(platform);
        vm.expectRevert(SweepAndBurn.OverMaxPrice.selector);
        sab.sweep(address(market), "", 5, 2e12, 1, 0);
        // the keeper cannot point the module at the JIG token or an unapproved contract
        vm.prank(platform);
        vm.expectRevert(SweepAndBurn.MarketNotAllowed.selector);
        sab.sweep(address(jig), "", 5, 0, 0, 0);
        vm.prank(creator);
        vm.expectRevert(SweepAndBurn.MarketNotAllowed.selector);
        sab.setMarket(address(jig), true);
    }

    // LOW (swarm audit 2): a JIG inflow during the marketplace call must not veto the sweep
    function test_sweep_survives_a_jig_inflow_during_the_market_call() public {
        SweepAndBurn sab = new SweepAndBurn(address(hook), address(nft), creator, platform, jigKey, 1e12);
        (, PoolKey memory key, bool coinIs0) = _launchCoin(address(sab));
        _buyCoin(key, coinIs0, 500_000e18);
        sab.pull();
        uint256 budget = jig.balanceOf(address(sab));
        _buyCoin(key, coinIs0, 100_000e18); // leaves a fresh claimable slice in the hook for the market to push
        assertGt(hook.claimable(address(sab)), 0);
        PushingMarket market = new PushingMarket(IERC721(address(nft)), seller, 5, 1e10, hook);
        vm.prank(seller);
        nft.setApprovalForAll(address(market), true);
        vm.prank(creator);
        sab.setMarket(address(market), true);
        vm.prank(platform);
        sab.sweep(address(market), abi.encodeCall(PushingMarket.buy, ()), 5, 1e10, budget, 1e10);
        assertEq(nft.ownerOf(5), sab.DEAD(), "burned despite the inflow");
    }

    // ---------- BuybackAndBurn ----------

    function test_buyback_and_burn() public {
        // the module needs the pool key, which exists only after launch: launch with flywheel = creator, then
        // deploy the module and lower nothing; instead test the module on a second coin launched with it.
        // Simplest: predict nothing, launch with a placeholder, then launch again with the real module.
        (, PoolKey memory k0, bool c0) = _launchCoin(address(0));
        k0;
        BuybackAndBurn bb = new BuybackAndBurn(address(hook), address(factory), address(nft), platform);
        // the flywheel for coin 0 was the creator (address(0) => creator). Give the module JIG directly instead.
        _buyCoin(k0, c0, 100_000e18);
        uint256 creatorSlice = hook.claimable(creator);
        vm.prank(creator);
        hook.claim();
        vm.prank(creator);
        jig.transfer(address(bb), creatorSlice);
        uint256 supplyBefore = bb.coin().totalSupply();
        vm.expectRevert(BuybackAndBurn.NotKeeper.selector);
        bb.run(0);
        vm.prank(platform);
        vm.expectRevert(BuybackAndBurn.TooLittleOut.selector);
        bb.run(type(uint256).max);
        vm.prank(platform);
        uint256 burnedCoin = bb.run(1);
        assertGt(burnedCoin, 0);
        assertEq(bb.coin().totalSupply(), supplyBefore - burnedCoin, "coin supply shrank");
        assertEq(bb.burned(), burnedCoin);
        assertEq(jig.balanceOf(address(bb)), 0, "the whole balance was spent");
        vm.prank(platform);
        vm.expectRevert(BuybackAndBurn.Nothing.selector);
        bb.run(0);
    }

    // ---------- LPDeepening ----------

    // Final audit (17 Oct), Medium 1: the deepening keeper can be replaced by the platform (the Safe) only
    function test_platform_replaces_the_deepening_keeper() public {
        address oldKeeper = makeAddr("oldKeeper"); address newKeeper = makeAddr("newKeeper");
        LPDeepening deep = new LPDeepening(address(hook), POSM, PERMIT2, jigKey, oldKeeper);
        vm.prank(buyer); jig.transfer(address(deep), 1_000_000e18);
        vm.prank(oldKeeper); vm.expectRevert(LPDeepening.NotPlatformAddr.selector); deep.setKeeper(newKeeper);
        vm.prank(platform); deep.setKeeper(newKeeper);
        vm.prank(oldKeeper); vm.expectRevert(LPDeepening.NotKeeper.selector); deep.run(1);
        vm.prank(newKeeper); deep.run(1);
        assertGt(deep.tokenId(), 0);
    }

    function test_lp_deepening_adds_locked_liquidity() public {
        LPDeepening deep = new LPDeepening(address(hook), POSM, PERMIT2, jigKey, platform);
        // hand it JIG as if it were its slice
        vm.prank(buyer);
        jig.transfer(address(deep), 1_000_000e18);
        vm.expectRevert(LPDeepening.NotKeeper.selector);
        deep.run(0);
        vm.prank(platform);
        deep.run(1);
        uint256 id = deep.tokenId();
        assertGt(id, 0);
        assertEq(IPositionManager(POSM).getPositionLiquidity(id) > 0, true);
        assertGt(deep.totalEthAdded(), 0);
        assertGt(deep.totalJigAdded(), 0);
        assertLt(jig.balanceOf(address(deep)), 1_000_000e18 / 100, "almost all JIG used");
        uint128 liq1 = IPositionManager(POSM).getPositionLiquidity(id);
        // second run increases the same position
        vm.prank(buyer);
        jig.transfer(address(deep), 500_000e18);
        vm.prank(platform);
        deep.run(1);
        assertEq(deep.tokenId(), id, "same position");
        assertGt(IPositionManager(POSM).getPositionLiquidity(id), liq1, "liquidity grew");
        deep.collectFees(); // no revert, fees (if any) go to the pot
    }

    // MEDIUM (swarm audit 2): fees accrued between runs must be paid to team/pot, not compounded into the locked position
    function test_lp_deepening_pays_accrued_fees_before_adding() public {
        LPDeepening deep = new LPDeepening(address(hook), POSM, PERMIT2, jigKey, platform);
        vm.prank(buyer);
        jig.transfer(address(deep), 1_000_000e18);
        vm.prank(platform);
        deep.run(1);
        // trade on the JIG pool so the deepening position accrues ETH fees
        address trader = makeAddr("trader");
        vm.deal(trader, 50 ether);
        for (uint256 i; i < 5; i++) {
            vm.prank(trader);
            swapper.swap{value: 5 ether}(jigKey, SwapParams({zeroForOne: true, amountSpecified: -int256(5 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        }
        uint256 before = address(pot).balance + platform.balance;
        uint128 liq1 = IPositionManager(POSM).getPositionLiquidity(deep.tokenId());
        vm.prank(buyer);
        jig.transfer(address(deep), 500_000e18);
        uint256 jigBefore = jig.balanceOf(address(pot)) + jig.balanceOf(platform);
        vm.prank(platform);
        deep.run(1); // must not revert and must pay the fees out first
        assertGt(address(pot).balance + platform.balance, before, "accrued LP fees reached team and pot");
        assertGt(jig.balanceOf(address(pot)) + jig.balanceOf(platform), jigBefore, "the run's own sale fee reached team and pot too (round 3)");
        assertGt(IPositionManager(POSM).getPositionLiquidity(deep.tokenId()), liq1, "and the run still deepened");
        assertEq(deep.platformOwedEth(), 0);
    }


    function _params(address collection, uint24 feePips, address flywheel, uint160 sqrtP, int24 lower, int24 upper) internal pure returns (CoinFactory.LaunchParams memory) {
        return CoinFactory.LaunchParams({collection: collection, name: "Cool", symbol: "COOL", feePips: feePips, flywheel: flywheel, creatorShareBps: type(uint16).max, creatorBps: 0, devBuyJig: 0, devBuyMinCoin: 0, maxFeeWei: 0.01 ether, salt: bytes32(bytes20(collection)), sqrtPriceX96: sqrtP, tickLower: lower, tickUpper: upper});
    }

    // ---------- SnapshotForwarder + HolderPayouts ----------

    // fees to coin holders, on chain (Jj, 17 Oct): RewardsForwarder hands the slice to the coin, which streams it
    function test_rewards_forwarder_streams_the_slice_to_holders() public {
        RewardsForwarder fwd = new RewardsForwarder(address(hook), address(factory), address(nft));
        vm.expectRevert(RewardsForwarder.NoCoinYet.selector);
        fwd.rewardsCoin();
        (CreatorCoin coin, PoolKey memory key, bool coinIs0) = _launchCoin(address(fwd));
        assertEq(address(fwd.rewardsCoin()), address(coin));
        assertEq(coin.notifier(), address(fwd), "the factory made the flywheel the notifier");
        _buyCoin(key, coinIs0, 100_000e18);
        uint256 slice = hook.claimable(address(fwd));
        assertGt(slice, 0);
        fwd.pull();
        assertEq(jig.balanceOf(address(fwd)), 0);
        assertEq(jig.balanceOf(address(coin)), slice, "the slice sits in the coin, streaming");
        vm.warp(block.timestamp + 7 days);
        uint256 b = coin.earned(buyer); uint256 c = coin.earned(creator);
        assertGt(b, 0);
        assertLe(b + c, slice, "never more than the slice");
        assertApproxEqRel(b + c, slice, 1e15, "all of it to the holders");
        assertEq(coin.earned(POOL_MANAGER), 0, "the pool's coins earn nothing");
        assertEq(coin.earned(address(airdrop)), 0, "nor does the airdrop's 5%");
        vm.prank(buyer); coin.claim();
        assertEq(jig.balanceOf(buyer) > 0, true);
    }

    // review, 17 Oct: each pull restarts the 7-day stream for what is left, so pulls are limited to one a day; a griefer
    // pulling after every trade could otherwise keep stretching holders' payouts
    function test_rewards_forwarder_pulls_at_most_once_a_day() public {
        RewardsForwarder fwd = new RewardsForwarder(address(hook), address(factory), address(nft));
        (, PoolKey memory key, bool coinIs0) = _launchCoin(address(fwd));
        _buyCoin(key, coinIs0, 100_000e18);
        fwd.pull();
        _buyCoin(key, coinIs0, 10_000e18);
        vm.expectRevert(RewardsForwarder.TooSoon.selector);
        fwd.pull();
        vm.warp(block.timestamp + 1 days);
        assertGt(fwd.pull(), 0, "a day later it pulls again");
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2; y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }
}
