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
    constructor() ERC721("Mock", "MOCK") {}
    function mint(address to, uint256 n) external { for (uint256 i; i < n; i++) _mint(to, ++totalSupply); }
}

/// A one-listing marketplace: pays the seller, hands the NFT to the buyer.
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

    function setUp() public {
        vm.createSelectFork("sepolia");
        pot = new PotVault(owner);
        launch = new JIGLaunch(POSM, PERMIT2, owner, address(pot));
        jig = new JIG(address(launch), address(pot));
        vesting = new Vesting();
        vm.startPrank(owner);
        launch.setJig(address(jig));
        // hookless JIG/ETH pool, 1%, $4k start, full range
        launch.launch(10_000, 200, address(0), 1980704062856608439838598758400000, -887_200, 202_400);
        vm.stopPrank();
        jigKey = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(jig)), fee: 10_000, tickSpacing: 200, hooks: IHooks(address(0))});

        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) | (uint160(0xF1F1) << 20));
        deployCodeTo("CreatorFeeHook.sol:CreatorFeeHook", abi.encode(POOL_MANAGER, address(jig), owner, platform, address(pot), address(pot)), hookAddr);
        hook = CreatorFeeHook(hookAddr);
        airdrop = new AirdropClaim(platform, address(pot));
        factory = new CoinFactory(POSM, PERMIT2, hookAddr, address(vesting), address(jig), platform, address(airdrop), 0.01 ether);
        vm.prank(owner);
        hook.setFactory(address(factory));

        nft = new MockNFT();
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
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        coinIs0 = predicted < address(jig);
        uint256 price = coinIs0 ? 1e18 / 1000 : 1000 * 1e18;
        uint160 sqrtP = uint160((_sqrt(price) * (1 << 96)) / 1e9);
        int24 startTick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 lower; int24 upper;
        if (coinIs0) { lower = (startTick / 200 + 1) * 200; upper = 887_200; } else { lower = -887_200; upper = (startTick / 200 - 1) * 200; }
        vm.prank(creator);
        (, address c) = factory.launch{value: 0.01 ether}(address(nft), "Cool", "COOL", 10_000, flywheel, address(0), sqrtP, lower, upper);
        coin = CreatorCoin(c);
        key = factory.poolKeyOf(factory.count() - 1);
        vm.warp(block.timestamp + 10 minutes); // past the snipe window
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
        vm.expectRevert("not owner");
        drip.claim(b);
    }

    // ---------- AirdropClaim ----------

    function test_airdrop_claim_and_sweep() public {
        (CreatorCoin coin,,) = _launchCoin(address(0));
        assertEq(coin.balanceOf(address(airdrop)), 50_000_000e18, "5% parked in AirdropClaim");
        bytes32 la = keccak256(bytes.concat(keccak256(abi.encode(holderA, uint256(30_000_000e18)))));
        bytes32 lb = keccak256(bytes.concat(keccak256(abi.encode(holderB, uint256(10_000_000e18)))));
        bytes32 root = la < lb ? keccak256(abi.encodePacked(la, lb)) : keccak256(abi.encodePacked(lb, la));
        vm.prank(platform);
        airdrop.setDrop(address(coin), root, 40_000_000e18, uint64(block.timestamp + 30 days));
        bytes32[] memory pa = new bytes32[](1); pa[0] = lb;
        airdrop.claim(address(coin), holderA, 30_000_000e18, pa);
        assertEq(coin.balanceOf(holderA), 30_000_000e18);
        vm.expectRevert(AirdropClaim.AlreadyClaimed.selector);
        airdrop.claim(address(coin), holderA, 30_000_000e18, pa);
        vm.expectRevert(AirdropClaim.NotExpired.selector);
        airdrop.sweep(address(coin));
        vm.warp(block.timestamp + 31 days);
        airdrop.sweep(address(coin));
        assertEq(coin.balanceOf(address(pot)), 20_000_000e18, "unclaimed B share + 10M unassigned to the pot");
        vm.prank(platform);
        vm.expectRevert(AirdropClaim.AlreadySet.selector);
        airdrop.setDrop(address(coin), root, 1, uint64(block.timestamp + 1 days));
    }

    // ---------- SweepAndBurn ----------

    function test_sweep_and_burn_buys_and_burns() public {
        SweepAndBurn sab = new SweepAndBurn(address(hook), address(nft), platform, jigKey, 1e12);
        (, PoolKey memory key, bool coinIs0) = _launchCoin(address(sab));
        _buyCoin(key, coinIs0, 500_000e18);
        sab.pull();
        uint256 budget = jig.balanceOf(address(sab));
        assertGt(budget, 0);

        MockMarket market = new MockMarket(IERC721(address(nft)), seller, 5, 1e10); // the module's JIG is small at a $4k start
        vm.prank(seller);
        nft.setApprovalForAll(address(market), true);

        // sell all of the module's JIG for ETH, buy token 5 at 0.001 ETH, burn it
        vm.prank(platform);
        sab.sweep(address(market), abi.encodeCall(MockMarket.buy, ()), 5, 1e10, budget);
        assertEq(nft.ownerOf(5), sab.DEAD(), "burned");
        assertEq(sab.burned(), 1);
        assertEq(seller.balance, 1e10);

        vm.prank(buyer);
        vm.expectRevert(SweepAndBurn.NotSweeper.selector);
        sab.sweep(address(market), "", 5, 1, 1);
        vm.prank(platform);
        vm.expectRevert(SweepAndBurn.OverMaxPrice.selector);
        sab.sweep(address(market), "", 5, 2e12, 1);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2; y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }
}
