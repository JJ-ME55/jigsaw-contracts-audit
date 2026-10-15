// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CreatorCoin} from "./CreatorCoin.sol";
import {CreatorFeeHook} from "./CreatorFeeHook.sol";
import {Vesting} from "./Vesting.sol";

/// @title CoinFactory
/// @notice Launches a creator coin for a collection (Build Spec §4). One call:
///         deploys the coin (fixed 1B supply), creates the coin/JIG v4 pool on the
///         shared CreatorFeeHook, seeds it single-sided with 90% of supply, holds the LP
///         NFT forever (no transfer or remove function), locks 5% for the creator in
///         Vesting (6 months) and sends 5% to the airdrop recipient (the AirdropClaim
///         contract once it exists; the pot until then). Takes a flat launch fee in ETH.
contract CoinFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint256 public constant POOL_SHARE = 900_000_000e18;
    uint256 public constant CREATOR_SHARE = 50_000_000e18;
    uint256 public constant AIRDROP_SHARE = 50_000_000e18;
    uint64 public constant CREATOR_VEST = 180 days;
    int24 public constant TICK_SPACING = 200;

    IPositionManager public immutable posm;
    IAllowanceTransfer public immutable permit2;
    CreatorFeeHook public immutable hook;
    Vesting public immutable vesting;
    IERC20 public immutable jig;
    address public immutable platform;
    address public immutable airdropRecipient;
    uint256 public immutable launchFeeWei;

    struct Launch {
        address coin;
        address collection;
        address creator;
        uint256 tokenId;
        uint256 vestingId;
        PoolKey key;
    }

    Launch[] public launches;
    mapping(address collection => address coin) public coinOf;

    event CoinLaunched(uint256 indexed index, address indexed coin, address indexed collection, address creator, uint24 feePips, address flywheel, uint256 tokenId);

    error ZeroAddress();
    error WrongFee();
    error CollectionHasCoin();
    error RangeWrongSide();
    error FeeSendFailed();
    error NotCollectionOwner();
    error PoolInitFailed();

    constructor(
        address posm_,
        address permit2_,
        address hook_,
        address vesting_,
        address jig_,
        address platform_,
        address airdropRecipient_,
        uint256 launchFeeWei_
    ) {
        if (posm_ == address(0) || permit2_ == address(0) || hook_ == address(0) || vesting_ == address(0) || jig_ == address(0) || platform_ == address(0) || airdropRecipient_ == address(0)) revert ZeroAddress();
        posm = IPositionManager(posm_);
        permit2 = IAllowanceTransfer(permit2_);
        hook = CreatorFeeHook(hook_);
        vesting = Vesting(vesting_);
        jig = IERC20(jig_);
        platform = platform_;
        airdropRecipient = airdropRecipient_;
        launchFeeWei = launchFeeWei_;
    }

    /// @param feePips creator-chosen fee, 10_000 (1%) to 100_000 (10%) in steps of 10_000
    /// @param flywheel module that receives the flywheel slice, address(0) = creator
    /// @param sqrtPriceX96 start price as sqrt(currency1 per currency0) * 2^96, computed off chain for the pair's ordering
    /// @param tickLower,tickUpper the seeded range, single-sided on the coin: entirely below the price if the coin is currency1,
    ///        entirely above it if the coin is currency0
    function launch(
        address collection,
        string calldata name,
        string calldata symbol,
        uint24 feePips,
        address flywheel,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper
    ) external payable nonReentrant returns (uint256 index, address coinAddr) {
        if (msg.value != launchFeeWei) revert WrongFee();
        if (collection == address(0) || collection.code.length == 0) revert ZeroAddress();
        if (coinOf[collection] != address(0)) revert CollectionHasCoin();
        if (!_controlsCollection(msg.sender, collection)) revert NotCollectionOwner();

        CreatorCoin coin = new CreatorCoin(name, symbol, SUPPLY, collection, address(this));
        coinAddr = address(coin);
        coinOf[collection] = coinAddr;

        bool coinIs0 = coinAddr < address(jig);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(coinIs0 ? coinAddr : address(jig)),
            currency1: Currency.wrap(coinIs0 ? address(jig) : coinAddr),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        int24 startTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        if (tickLower >= tickUpper) revert RangeWrongSide();
        if (coinIs0 ? tickLower <= startTick : tickUpper > startTick) revert RangeWrongSide();

        hook.register(key, msg.sender, flywheel, feePips);
        if (posm.initializePool(key, sqrtPriceX96) == type(int24).max) revert PoolInitFailed();

        uint128 liquidity = coinIs0
            ? LiquidityAmounts.getLiquidityForAmount0(TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), POOL_SHARE)
            : LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), POOL_SHARE);

        coin.approve(address(permit2), POOL_SHARE);
        permit2.approve(coinAddr, address(posm), uint160(POOL_SHARE), uint48(block.timestamp + 1 hours));

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, coinIs0 ? uint128(POOL_SHARE) : 0, coinIs0 ? 0 : uint128(POOL_SHARE), address(this), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        uint256 tokenId = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        coin.approve(address(vesting), CREATOR_SHARE);
        uint256 vestingId = vesting.create(coinAddr, msg.sender, CREATOR_SHARE, 0, 0, CREATOR_VEST);
        IERC20(coinAddr).safeTransfer(airdropRecipient, AIRDROP_SHARE);
        // let an AirdropClaim start its unset-drop clock; a plain address ignores this
        (bool noted,) = airdropRecipient.call(abi.encodeWithSignature("notify(address)", coinAddr));
        noted;

        index = launches.length;
        launches.push(Launch({coin: coinAddr, collection: collection, creator: msg.sender, tokenId: tokenId, vestingId: vestingId, key: key}));

        (bool ok,) = platform.call{value: msg.value}("");
        if (!ok) revert FeeSendFailed();
        emit CoinLaunched(index, coinAddr, collection, msg.sender, feePips, flywheel, tokenId);
    }

    /// @dev The caller must be the collection's owner() or creator() (both exist on LoomCollection).
    function _controlsCollection(address who, address collection) internal view returns (bool) {
        (bool ok, bytes memory ret) = collection.staticcall(abi.encodeWithSignature("owner()"));
        if (ok && ret.length == 32 && abi.decode(ret, (address)) == who) return true;
        (ok, ret) = collection.staticcall(abi.encodeWithSignature("creator()"));
        if (ok && ret.length == 32 && abi.decode(ret, (address)) == who) return true;
        return false;
    }

    function count() external view returns (uint256) {
        return launches.length;
    }

    function poolKeyOf(uint256 index) external view returns (PoolKey memory) {
        return launches[index].key;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
