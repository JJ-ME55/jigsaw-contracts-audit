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
///         address is the `flywheel` passed to CoinFactory.
///
///         Only the keeper (the platform's back end) may run it, at times of its choosing,
///         and every run spends the whole balance. The keeper passes a minimum amount of
///         coin it expects back, quoted off chain, so a run cannot be sandwiched below that.
contract BuybackAndBurn is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    CreatorFeeHook public immutable hook;
    IERC20 public immutable jig;
    IPoolManager public immutable poolManager;
    CreatorCoin public immutable coin;
    address public immutable keeper;
    PoolKey public key;
    bool public immutable coinIs0;

    uint256 public burned;

    event Burned(uint256 jigSpent, uint256 coinBurned);

    error NotKeeper();
    error NotPoolManager();
    error ZeroAddress();
    error Nothing();
    error TooLittleOut();

    constructor(address hook_, PoolKey memory key_, address keeper_) {
        if (hook_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        hook = CreatorFeeHook(hook_);
        jig = hook.jig();
        poolManager = hook.poolManager();
        keeper = keeper_;
        key = key_;
        coinIs0 = Currency.unwrap(key_.currency0) != address(jig);
        coin = CreatorCoin(Currency.unwrap(coinIs0 ? key_.currency0 : key_.currency1));
    }

    /// @notice Pull the slice from the hook, buy the coin with all of it, burn what arrives.
    /// @param minCoinOut the least coin the keeper will accept for the whole balance (off-chain quote minus tolerance)
    function run(uint256 minCoinOut) external nonReentrant returns (uint256 coinBurned) {
        if (msg.sender != keeper) revert NotKeeper();
        hook.claim();
        uint256 amount = jig.balanceOf(address(this));
        if (amount == 0) revert Nothing();
        uint256 before = coin.balanceOf(address(this));
        uint256 spent = abi.decode(poolManager.unlock(abi.encode(amount)), (uint256));
        coinBurned = coin.balanceOf(address(this)) - before;
        if (coinBurned < minCoinOut || coinBurned == 0) revert TooLittleOut();
        coin.burn(coinBurned);
        burned += coinBurned;
        emit Burned(spent, coinBurned);
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
        uint256 spent = uint256(uint128(-jigDelta));
        if (spent > 0) {
            poolManager.sync(jigC);
            jig.safeTransfer(address(poolManager), spent);
            poolManager.settle();
        }
        uint256 got = uint256(uint128(coinDelta));
        if (got > 0) poolManager.take(coinC, address(this), got);
        return abi.encode(spent);
    }
}
