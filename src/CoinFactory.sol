// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CreatorCoin} from "./CreatorCoin.sol";
import {CreatorFeeHook} from "./CreatorFeeHook.sol";

interface IAirdropNotify {
    function notify(address coin) external;
}

/// @title CoinFactory
/// @notice Launches a creator coin for a collection (Build Spec §4, revised 15 Oct). One call:
///         deploys the coin (fixed 1B supply), creates the coin/JIG v4 pool on the shared
///         CreatorFeeHook, seeds it single-sided, holds the LP NFT forever (no transfer or
///         remove function), sends 5% to the airdrop recipient, and gives the creator what
///         they chose: up to 5% of supply straight to their wallet, and/or a dev buy with
///         JIG in the same transaction before anyone else can trade. Takes a flat launch fee
///         in ETH that the platform can update to track a dollar price.
contract CoinFactory is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint256 public constant AIRDROP_SHARE = 50_000_000e18; // 5%
    uint16 public constant MAX_CREATOR_BPS = 500; // up to 5% of supply to the creator's wallet
    int24 public constant TICK_SPACING = 200;

    IPositionManager public immutable posm;
    IPoolManager public immutable poolManager;
    IAllowanceTransfer public immutable permit2;
    CreatorFeeHook public immutable hook;
    IERC20 public immutable jig;
    address public immutable platform;
    address public immutable airdropRecipient;
    uint256 public launchFeeWei;

    struct Launch {
        address coin;
        address collection;
        address creator;
        uint256 tokenId;
        PoolKey key;
    }

    struct LaunchParams {
        address collection;
        string name;
        string symbol;
        uint24 feePips; // 10_000 (1%) .. 100_000 (10%) in steps of 10_000
        address flywheel; // module for the flywheel slice; address(0) = creator wallet
        uint16 creatorShareBps; // creator's share of the fee within the creator+flywheel block; type(uint16).max = default (flywheel 20%), 0 = everything to the flywheel
        uint16 creatorBps; // share of supply to the creator's wallet at launch, 0..500 (0..5%)
        uint256 devBuyJig; // JIG the creator spends buying the coin in this transaction, 0 for none (needs approval)
        uint256 devBuyMinCoin; // slippage floor for the dev buy
        uint256 maxFeeWei; // the most the creator agrees to pay as launch fee (the quote plus their tolerance)
        uint160 sqrtPriceX96; // start price as sqrt(currency1 per currency0) * 2^96, for the pair's ordering
        int24 tickLower; // seeded range, single-sided on the coin
        int24 tickUpper;
    }

    Launch[] public launches;
    mapping(address collection => address coin) public coinOf;
    mapping(address collection => PoolKey) private _keyOf;

    event CoinLaunched(uint256 indexed index, address indexed coin, address indexed collection, address creator, uint24 feePips, address flywheel, uint256 tokenId, uint256 creatorTokens, uint256 devBuyJig, uint256 devBuyCoin);
    event LaunchFeeSet(uint256 launchFeeWei);

    error BadAirdropRecipient();
    error ZeroAddress();
    error WrongFee();
    error CollectionHasCoin();
    error RangeWrongSide();
    error FeeSendFailed();
    error NotCollectionOwner();
    error PoolInitFailed();
    error NotPlatform();
    error NotPoolManager();
    error TooMuchCreator();
    error TooLittleOut();

    constructor(address posm_, address permit2_, address hook_, address jig_, address platform_, address airdropRecipient_, uint256 launchFeeWei_) {
        if (posm_ == address(0) || permit2_ == address(0) || hook_ == address(0) || jig_ == address(0) || platform_ == address(0) || airdropRecipient_ == address(0)) revert ZeroAddress();
        posm = IPositionManager(posm_);
        poolManager = IPositionManager(posm_).poolManager();
        permit2 = IAllowanceTransfer(permit2_);
        hook = CreatorFeeHook(hook_);
        jig = IERC20(jig_);
        platform = platform_;
        // a contract recipient must answer AirdropClaim.pot(): the strict notify() in launch() would otherwise revert every launch
        if (airdropRecipient_.code.length > 0) {
            (bool ok, bytes memory ret) = airdropRecipient_.staticcall(abi.encodeWithSignature("pot()"));
            if (!ok || ret.length != 32) revert BadAirdropRecipient();
            // and it must not already be bound to another factory: notify() would revert NotFactory on every launch
            (bool ok2, bytes memory ret2) = airdropRecipient_.staticcall(abi.encodeWithSignature("factory()"));
            if (!ok2 || ret2.length != 32 || abi.decode(ret2, (address)) != address(0)) revert BadAirdropRecipient();
        }
        airdropRecipient = airdropRecipient_;
        launchFeeWei = launchFeeWei_;
    }

    /// @notice The platform updates the ETH launch fee to track its dollar price.
    function setLaunchFee(uint256 launchFeeWei_) external {
        if (msg.sender != platform) revert NotPlatform();
        launchFeeWei = launchFeeWei_;
        emit LaunchFeeSet(launchFeeWei_);
    }

    function launch(LaunchParams calldata p) external payable nonReentrant returns (uint256 index, address coinAddr) {
        uint256 fee = launchFeeWei; // read once: paid and refunded against the same number
        if (msg.value < fee || fee > p.maxFeeWei) revert WrongFee(); // a fee update before a quoted launch is fine up to the creator's stated maximum; excess is refunded
        if (p.collection == address(0) || p.collection.code.length == 0) revert ZeroAddress();
        if (p.creatorBps > MAX_CREATOR_BPS) revert TooMuchCreator();
        if (coinOf[p.collection] != address(0)) revert CollectionHasCoin();
        if (!_controlsCollection(msg.sender, p.collection)) revert NotCollectionOwner();

        CreatorCoin coin = new CreatorCoin(p.name, p.symbol, SUPPLY, p.collection, address(this));
        coinAddr = address(coin);
        coinOf[p.collection] = coinAddr;

        bool coinIs0 = coinAddr < address(jig);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(coinIs0 ? coinAddr : address(jig)),
            currency1: Currency.wrap(coinIs0 ? address(jig) : coinAddr),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        int24 startTick = TickMath.getTickAtSqrtPrice(p.sqrtPriceX96);
        if (p.tickLower >= p.tickUpper) revert RangeWrongSide();
        // coin as currency0: the range must sit above the price; the boundary tick is allowed only at its exact price
        if (coinIs0 ? (p.tickLower < startTick || (p.tickLower == startTick && p.sqrtPriceX96 != TickMath.getSqrtPriceAtTick(startTick))) : p.tickUpper > startTick) revert RangeWrongSide();

        _keyOf[p.collection] = key;
        hook.register(key, msg.sender, p.flywheel, p.feePips, p.creatorShareBps, p.tickLower, p.tickUpper);
        if (posm.initializePool(key, p.sqrtPriceX96) == type(int24).max) revert PoolInitFailed();

        uint256 creatorTokens = (SUPPLY * p.creatorBps) / 10_000;
        uint256 tokenId = _seed(coin, key, coinIs0, SUPPLY - AIRDROP_SHARE - creatorTokens, p.tickLower, p.tickUpper);
        hook.seal(key); // the factory's position is the only liquidity this pool will ever have

        if (creatorTokens > 0) IERC20(coinAddr).safeTransfer(msg.sender, creatorTokens);
        IERC20(coinAddr).safeTransfer(airdropRecipient, AIRDROP_SHARE);
        if (airdropRecipient.code.length > 0) IAirdropNotify(airdropRecipient).notify(coinAddr); // a contract recipient must accept the clock

        uint256 devBuyCoin;
        if (p.devBuyJig > 0) devBuyCoin = _devBuy(key, coinIs0, coinAddr, p.devBuyJig, p.devBuyMinCoin);

        index = launches.length;
        launches.push(Launch({coin: coinAddr, collection: p.collection, creator: msg.sender, tokenId: tokenId, key: key}));

        (bool ok,) = platform.call{value: fee}("");
        if (!ok) revert FeeSendFailed();
        if (msg.value > fee) {
            (bool r,) = msg.sender.call{value: msg.value - fee}("");
            if (!r) revert FeeSendFailed();
        }
        emit CoinLaunched(index, coinAddr, p.collection, msg.sender, p.feePips, p.flywheel, tokenId, creatorTokens, p.devBuyJig, devBuyCoin);
    }

    function _seed(CreatorCoin coin, PoolKey memory key, bool coinIs0, uint256 poolShare, int24 tickLower, int24 tickUpper) internal returns (uint256 tokenId) {
        uint128 liquidity = coinIs0
            ? LiquidityAmounts.getLiquidityForAmount0(TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), poolShare)
            : LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), poolShare);
        coin.approve(address(permit2), poolShare);
        permit2.approve(address(coin), address(posm), uint160(poolShare), uint48(block.timestamp + 1 hours));
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, coinIs0 ? uint128(poolShare) : 0, coinIs0 ? 0 : uint128(poolShare), address(this), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        tokenId = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @dev Creator's dev buy: pull JIG from the creator, swap it for the coin on the fresh pool, send the coin to the creator.
    function _devBuy(PoolKey memory key, bool coinIs0, address coinAddr, uint256 jigIn, uint256 minOut) internal returns (uint256 got) {
        jig.safeTransferFrom(msg.sender, address(this), jigIn);
        (uint256 got_, uint256 spent) = abi.decode(poolManager.unlock(abi.encode(key, coinIs0, jigIn)), (uint256, uint256));
        got = got_;
        if (got < minOut || got == 0) revert TooLittleOut();
        IERC20(coinAddr).safeTransfer(msg.sender, got);
        if (jigIn > spent) jig.safeTransfer(msg.sender, jigIn - spent); // a partial fill refunds only this buy's unspent JIG
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool coinIs0, uint256 jigIn) = abi.decode(data, (PoolKey, bool, uint256));
        bool zeroForOne = !coinIs0; // JIG in, coin out
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(jigIn), sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            ""
        );
        Currency jigC = coinIs0 ? key.currency1 : key.currency0;
        Currency coinC = coinIs0 ? key.currency0 : key.currency1;
        int128 jigDelta = coinIs0 ? d.amount1() : d.amount0();
        int128 coinDelta = coinIs0 ? d.amount0() : d.amount1();
        uint256 spent = uint256(uint128(-jigDelta));
        if (spent > 0) {
            poolManager.sync(jigC);
            jig.safeTransfer(address(poolManager), spent);
            poolManager.settle();
        }
        uint256 got = uint256(uint128(coinDelta));
        if (got > 0) poolManager.take(coinC, address(this), got);
        return abi.encode(got, spent);
    }

    /// @dev The caller must be the collection's creator(). Only a collection with no creator() falls back to owner():
    ///      on LoomCollection the owner is whoever launched it, which is the platform's wallet for site-launched
    ///      collections, and the platform must not be able to claim an artist's coin.
    function _controlsCollection(address who, address collection) internal view returns (bool) {
        (bool ok, bytes memory ret) = collection.staticcall(abi.encodeWithSignature("creator()"));
        if (ok && ret.length == 32) return abi.decode(ret, (address)) == who;
        (ok, ret) = collection.staticcall(abi.encodeWithSignature("owner()"));
        if (ok && ret.length == 32) return abi.decode(ret, (address)) == who;
        return false;
    }

    function count() external view returns (uint256) {
        return launches.length;
    }

    function poolKeyOf(uint256 index) external view returns (PoolKey memory) {
        return launches[index].key;
    }

    /// @notice The pool key of a collection's coin (zero key if none launched).
    function keyOf(address collection) external view returns (PoolKey memory) {
        return _keyOf[collection];
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
