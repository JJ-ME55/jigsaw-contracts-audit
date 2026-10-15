// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CreatorFeeHook} from "./CreatorFeeHook.sol";
import {CreatorCoin} from "./CreatorCoin.sol";

/// @title BuybackAndBurn
/// @notice Flywheel module (Build Spec §4, "buyback and burn"): the coin's flywheel slice
///         buys the coin back on its own pool and burns it. One instance per coin; its
///         address is the `flywheel` passed to CoinFactory. Anyone can trigger a run.
contract BuybackAndBurn is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    CreatorFeeHook public immutable hook;
    IERC20 public immutable jig;
    IPoolManager public immutable poolManager;
    CreatorCoin public immutable coin;
    PoolKey public key;
    bool public immutable coinIs0;

    uint256 public burned;

    event Burned(uint256 jigSpent, uint256 coinBurned);

    error NotPoolManager();
    error ZeroAddress();
    error Nothing();

    constructor(address hook_, PoolKey memory key_) {
        if (hook_ == address(0)) revert ZeroAddress();
        hook = CreatorFeeHook(hook_);
        jig = hook.jig();
        poolManager = hook.poolManager();
        key = key_;
        coinIs0 = Currency.unwrap(key_.currency0) != address(jig);
        coin = CreatorCoin(Currency.unwrap(coinIs0 ? key_.currency0 : key_.currency1));
    }

    /// @notice Pull the slice from the hook, buy the coin with all of it, burn what arrives.
    function run() external nonReentrant returns (uint256 coinBurned) {
        uint256 amount = hook.claim() + jig.balanceOf(address(this));
        if (amount == 0) revert Nothing();
        uint256 before = coin.balanceOf(address(this));
        poolManager.unlock(abi.encode(amount));
        coinBurned = coin.balanceOf(address(this)) - before;
        coin.burn(coinBurned);
        burned += coinBurned;
        emit Burned(amount, coinBurned);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        bool zeroForOne = !coinIs0; // JIG in, coin out
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            ""
        );
        Currency jigC = coinIs0 ? key.currency1 : key.currency0;
        Currency coinC = coinIs0 ? key.currency0 : key.currency1;
        int128 jigDelta = coinIs0 ? d.amount1() : d.amount0();
        int128 coinDelta = coinIs0 ? d.amount0() : d.amount1();
        poolManager.sync(jigC);
        jig.safeTransfer(address(poolManager), uint256(uint128(-jigDelta)));
        poolManager.settle();
        poolManager.take(coinC, address(this), uint256(uint128(coinDelta)));
        return "";
    }
}
