// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CreatorFeeHook} from "./CreatorFeeHook.sol";
import {CreatorCoin} from "./CreatorCoin.sol";

/// @title BuybackAndBurn
/// @notice Flywheel module (Build Spec §4, "buyback and burn"): the coin's flywheel slice
///         buys the coin back on its own pool and burns it. One instance per coin; its
///         address is the `flywheel` passed to CoinFactory. Anyone can trigger a run.
///
///         MEV limits: at most maxPerRun JIG per run, one run per COOLDOWN, and the swap may
///         move the price at most ~MAX_IMPACT_BPS past a reference recorded by observe() in
///         an earlier block, so a same-transaction pump cannot widen the bound. Whatever does
///         not fill stays for the next run.
contract BuybackAndBurn is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint64 public constant COOLDOWN = 10 minutes;
    uint256 public constant MAX_IMPACT_BPS = 300; // 3% price move per run

    CreatorFeeHook public immutable hook;
    IERC20 public immutable jig;
    IPoolManager public immutable poolManager;
    CreatorCoin public immutable coin;
    PoolKey public key;
    bool public immutable coinIs0;
    uint256 public immutable maxPerRun;

    uint64 public lastRun;
    uint256 public burned;
    /// @dev Reference price recorded in an earlier block, so a caller cannot set the bound in the same tx.
    uint160 public refSqrtPriceX96;
    uint64 public refBlock;
    uint64 public constant REF_MAX_AGE = 256; // blocks

    event Burned(uint256 jigSpent, uint256 coinBurned);

    error NotPoolManager();
    error ZeroAddress();
    error Nothing();
    error TooSoon();
    error NoReference();

    constructor(address hook_, PoolKey memory key_, uint256 maxPerRun_) {
        if (hook_ == address(0) || maxPerRun_ == 0) revert ZeroAddress();
        hook = CreatorFeeHook(hook_);
        jig = hook.jig();
        poolManager = hook.poolManager();
        key = key_;
        coinIs0 = Currency.unwrap(key_.currency0) != address(jig);
        coin = CreatorCoin(Currency.unwrap(coinIs0 ? key_.currency0 : key_.currency1));
        maxPerRun = maxPerRun_;
    }

    /// @notice Record the pool price for a later run. Must be called in an earlier block than run().
    function observe() external {
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        refSqrtPriceX96 = sqrtP;
        refBlock = uint64(block.number);
    }

    /// @notice Pull the slice from the hook, buy the coin with up to maxPerRun of it, burn what arrives.
    ///         Needs observe() from an earlier block (at most REF_MAX_AGE blocks ago).
    function run() external nonReentrant returns (uint256 coinBurned) {
        if (block.timestamp < lastRun + COOLDOWN) revert TooSoon();
        if (refBlock == 0 || block.number <= refBlock || block.number - refBlock > REF_MAX_AGE) revert NoReference();
        hook.claim();
        uint256 amount = jig.balanceOf(address(this));
        if (amount > maxPerRun) amount = maxPerRun;
        if (amount == 0) revert Nothing();
        uint256 before = coin.balanceOf(address(this));
        uint256 spent = abi.decode(poolManager.unlock(abi.encode(amount)), (uint256));
        if (spent == 0) revert Nothing(); // no liquidity inside the bound: do not burn the cooldown
        lastRun = uint64(block.timestamp);
        coinBurned = coin.balanceOf(address(this)) - before;
        if (coinBurned > 0) coin.burn(coinBurned);
        burned += coinBurned;
        emit Burned(spent, coinBurned);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        bool zeroForOne = !coinIs0; // JIG in, coin out
        (uint160 spot,,,) = poolManager.getSlot0(key.toId());
        // Bound against the lagged reference: a same-block pump cannot widen it. zeroForOne pushes the price down,
        // so the base is the higher of the two; oneForZero pushes it up, so the base is the lower.
        uint160 base = zeroForOne ? (spot > refSqrtPriceX96 ? spot : refSqrtPriceX96) : (spot < refSqrtPriceX96 ? spot : refSqrtPriceX96);
        // sqrt price moves by about half the price move: 3% price => ~1.5% sqrt price
        uint160 limit = zeroForOne
            ? uint160((uint256(base) * (10_000 - MAX_IMPACT_BPS / 2)) / 10_000)
            : uint160((uint256(base) * (10_000 + MAX_IMPACT_BPS / 2)) / 10_000);
        // if the spot is already past the bound, fill nothing rather than revert the manager
        if (zeroForOne ? spot <= limit : spot >= limit) return abi.encode(uint256(0));
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = poolManager.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: limit}), "");
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
