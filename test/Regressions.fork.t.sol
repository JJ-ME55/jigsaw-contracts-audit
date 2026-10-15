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
import {ReferrerRegistry} from "../src/ReferrerRegistry.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract OwnedNFT is ERC721 {
    uint256 public totalSupply;
    address public owner;
    constructor(address o) ERC721("Mock", "MOCK") { owner = o; }
    function mint(address to, uint256 n) external { for (uint256 i; i < n; i++) _mint(to, ++totalSupply); }
}

/// Pins the fixes from the 15 Oct 2026 adversarial review. forge test --match-contract RegressionsFork --fork-url sepolia
contract RegressionsForkTest is Test {
    using PoolIdLibrary for PoolKey;

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

    PotVault pot; JIG jig; Vesting vesting; JIGLaunch launch; CreatorFeeHook hook; CoinFactory factory;
    ReferrerRegistry registry; OwnedNFT nft; PoolSwapTest swapper; PoolKey jigKey;

    function setUp() public {
        vm.createSelectFork("sepolia");
        pot = new PotVault(owner);
        launch = new JIGLaunch(POSM, PERMIT2, owner, address(pot));
        jig = new JIG(address(launch), address(pot));
        vesting = new Vesting();
        vm.startPrank(owner);
        launch.setJig(address(jig));
        launch.launch(10_000, 200, address(0), TickMath.getSqrtPriceAtTick(202_400), -887_200, 202_400);
        vm.stopPrank();
        jigKey = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(jig)), fee: 10_000, tickSpacing: 200, hooks: IHooks(address(0))});
        registry = new ReferrerRegistry(platform);
        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) | (uint160(0xC0DE) << 20));
        deployCodeTo("CreatorFeeHook.sol:CreatorFeeHook", abi.encode(POOL_MANAGER, address(jig), owner, platform, address(pot), address(registry)), hookAddr);
        hook = CreatorFeeHook(hookAddr);
        factory = new CoinFactory(POSM, PERMIT2, hookAddr, address(vesting), address(jig), platform, address(pot), 0.01 ether);
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
        (, address c) = factory.launch{value: 0.01 ether}(address(nft), "Cool", "COOL", 10_000, flywheel, address(0), sqrtP, lower, upper);
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
        factory.launch{value: 0.01 ether}(address(nft), "x", "x", 10_000, address(0), address(0), 1 << 96, -200, 0);
        vm.prank(creator);
        vm.expectRevert(CoinFactory.ZeroAddress.selector);
        factory.launch{value: 0.01 ether}(makeAddr("eoa"), "x", "x", 10_000, address(0), address(0), 1 << 96, -200, 0);
        _launchCoin(creator, address(0));
        assertEq(factory.count(), 1);
    }

    // HIGH: pot could never claim
    function test_anyone_can_push_the_pot_its_slice() public {
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        vm.warp(block.timestamp + 10 minutes);
        _swap(buyer, key, !coinIs0, -100_000e18, "");
        uint256 owed = hook.claimable(address(pot));
        assertGt(owed, 0);
        uint256 before = jig.balanceOf(address(pot));
        hook.claimFor(address(pot));
        assertEq(jig.balanceOf(address(pot)) - before, owed);
        assertEq(hook.claimable(address(pot)), 0);
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

    // LOW: self-referral
    function test_unapproved_trade_referral_goes_to_platform() public {
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(0));
        vm.warp(block.timestamp + 10 minutes);
        _swap(buyer, key, !coinIs0, -100_000e18, abi.encode(buyer));
        uint256 total = hook.totalClaimable();
        assertEq(hook.claimable(buyer), 0, "no self rebate");
        assertApproxEqAbs(hook.claimable(platform), total * (1500 + 1000 + 1000) / 10_000, 3, "platform: its band + trade ref + launch ref");
        vm.prank(platform);
        registry.setReferrer(late, true);
        _swap(buyer, key, !coinIs0, -100_000e18, abi.encode(late));
        assertGt(hook.claimable(late), 0, "approved referrer is paid");
    }

    // HIGH: post-pull mints over-claim the drip
    function test_tokens_minted_after_a_pull_earn_nothing_from_it() public {
        HolderDrip drip = new HolderDrip(address(hook), address(nft));
        (, PoolKey memory key, bool coinIs0) = _launchCoin(creator, address(drip));
        vm.warp(block.timestamp + 10 minutes);
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

    // MEDIUM: owner self-payout needs to wait the delay
    function test_pot_declare_has_a_delay() public {
        vm.startPrank(owner);
        pot.enablePayouts();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(owner, uint256(1e18)))));
        vm.expectRevert(PotVault.BadDistribution.selector);
        pot.declare(address(jig), leaf, 1e18, uint64(block.timestamp + 1 days)); // expiry inside the delay
        uint256 id = pot.declare(address(jig), leaf, 1e18, uint64(block.timestamp + 30 days));
        vm.stopPrank();
        vm.expectRevert(PotVault.NotYet.selector);
        pot.claim(id, owner, 1e18, new bytes32[](0));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2; y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }
}
