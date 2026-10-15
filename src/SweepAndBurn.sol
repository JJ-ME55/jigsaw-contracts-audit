// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CreatorFeeHook} from "./CreatorFeeHook.sol";

/// @title SweepAndBurn
/// @notice Flywheel module (Build Spec §4, "sweep and burn"): the coin's flywheel slice
///         buys the cheapest listed NFT of the collection and burns it. One instance per
///         coin; its address is the `flywheel` passed to CoinFactory.
///
///         The module holds JIG (pulled from the hook). A sweep: swap JIG for ETH on the
///         JIG/ETH pool, pay a marketplace order with that ETH, confirm the NFT arrived,
///         send it to the dead address. Which listing is cheapest cannot be known on
///         chain, so the sweeper role (the platform's keeper) supplies the marketplace
///         call. The module checks the price fits its budget, the NFT is from this
///         collection, and it actually arrived, so the keeper can at worst overpay for a
///         real NFT of the right collection, never take funds. `maxPriceWei` caps that.
contract SweepAndBurn is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    CreatorFeeHook public immutable hook;
    IERC20 public immutable jig;
    IERC721 public immutable collection;
    IPoolManager public immutable poolManager;
    address public immutable sweeper;
    PoolKey public jigPool; // ETH / JIG

    uint256 public maxPriceWei;
    uint256 public burned;

    event Pulled(uint256 jig);
    event Swept(uint256 indexed tokenId, uint256 priceWei, uint256 jigSold);
    event MaxPriceSet(uint256 maxPriceWei);

    error NotSweeper();
    error ZeroAddress();
    error OverBudget();
    error OverMaxPrice();
    error NotReceived();
    error NotPoolManager();
    error MarketplaceCallFailed();

    constructor(address hook_, address collection_, address sweeper_, PoolKey memory jigPool_, uint256 maxPriceWei_) {
        if (hook_ == address(0) || collection_ == address(0) || sweeper_ == address(0)) revert ZeroAddress();
        hook = CreatorFeeHook(hook_);
        jig = hook.jig();
        poolManager = hook.poolManager();
        collection = IERC721(collection_);
        sweeper = sweeper_;
        jigPool = jigPool_;
        maxPriceWei = maxPriceWei_;
    }

    /// @notice Pull this module's claimable JIG from the hook. Anyone may call.
    function pull() external nonReentrant returns (uint256 amount) {
        amount = hook.claim();
        emit Pulled(amount);
    }

    function setMaxPrice(uint256 maxPriceWei_) external {
        if (msg.sender != sweeper) revert NotSweeper();
        maxPriceWei = maxPriceWei_;
        emit MaxPriceSet(maxPriceWei_);
    }

    /// @notice Buy `tokenId` through `marketplace` for `priceWei` using JIG converted to ETH, then burn it.
    /// @param jigToSell how much JIG to swap for ETH; must yield at least priceWei
    function sweep(address marketplace, bytes calldata data, uint256 tokenId, uint256 priceWei, uint256 jigToSell)
        external
        nonReentrant
    {
        if (msg.sender != sweeper) revert NotSweeper();
        if (priceWei > maxPriceWei) revert OverMaxPrice();
        if (jigToSell > jig.balanceOf(address(this))) revert OverBudget();

        uint256 ethBefore = address(this).balance;
        poolManager.unlock(abi.encode(jigToSell));
        uint256 ethGot = address(this).balance - ethBefore;
        if (ethGot < priceWei) revert OverBudget();

        (bool ok,) = marketplace.call{value: priceWei}(data);
        if (!ok) revert MarketplaceCallFailed();
        if (collection.ownerOf(tokenId) != address(this)) revert NotReceived();

        collection.transferFrom(address(this), DEAD, tokenId);
        burned++;
        emit Swept(tokenId, priceWei, jigToSell);
    }

    /// @dev Sell JIG for ETH on the JIG/ETH pool. JIG is currency1 (ETH is address 0), so this is oneForZero.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        BalanceDelta d = poolManager.swap(
            jigPool, SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), ""
        );
        poolManager.sync(jigPool.currency1);
        jig.safeTransfer(address(poolManager), uint256(uint128(-d.amount1())));
        poolManager.settle();
        poolManager.take(jigPool.currency0, address(this), uint256(uint128(d.amount0())));
        return "";
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
