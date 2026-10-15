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
import {CoinFactory} from "./CoinFactory.sol";

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
    CoinFactory public immutable factory;
    address public immutable collection;
    address public immutable keeper;

    uint256 public burned;

    event Burned(uint256 jigSpent, uint256 coinBurned);

    error NotKeeper();
    error NotPoolManager();
    error ZeroAddress();
    error Nothing();
    error TooLittleOut();
    error NoCoinYet();

    constructor(address hook_, address factory_, address collection_, address keeper_) {
        if (hook_ == address(0) || factory_ == address(0) || collection_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        hook = CreatorFeeHook(hook_);
        jig = hook.jig();
        poolManager = hook.poolManager();
        factory = CoinFactory(factory_);
        collection = collection_;
        keeper = keeper_;
    }

    /// @notice The coin and pool this module serves, read from the factory.
    function coin() public view returns (CreatorCoin c) {
        address a = factory.coinOf(collection);
        if (a == address(0)) revert NoCoinYet();
        c = CreatorCoin(a);
    }

    function key() public view returns (PoolKey memory) {
        return factory.keyOf(collection);
    }

    function coinIs0() public view returns (bool) {
        return Currency.unwrap(key().currency0) != address(jig);
    }

    /// @notice Pull this module's slice from the hook into its balance. Anyone may call, so the balance can never go stale.
    function pull() external nonReentrant returns (uint256 amount) {
        amount = hook.claim();
    }

    /// @notice Pull the slice from the hook, buy the coin with all of it, burn what arrives.
    /// @param minCoinOut the least coin the keeper will accept for the whole balance (off-chain quote minus tolerance)
    function run(uint256 minCoinOut) external nonReentrant returns (uint256 coinBurned) {
        if (msg.sender != keeper) revert NotKeeper();
        hook.claim();
        uint256 amount = jig.balanceOf(address(this));
        if (amount == 0) revert Nothing();
        CreatorCoin c = coin();
        uint256 before = c.balanceOf(address(this));
        uint256 spent = abi.decode(poolManager.unlock(abi.encode(amount)), (uint256));
        coinBurned = c.balanceOf(address(this)) - before;
        if (coinBurned < minCoinOut || coinBurned == 0) revert TooLittleOut();
        c.burn(coinBurned);
        burned += coinBurned;
        emit Burned(spent, coinBurned);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        PoolKey memory k = key();
        bool c0 = coinIs0();
        bool zeroForOne = !c0; // JIG in, coin out
        BalanceDelta d = poolManager.swap(
            k,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            ""
        );
        Currency jigC = c0 ? k.currency1 : k.currency0;
        Currency coinC = c0 ? k.currency0 : k.currency1;
        int128 jigDelta = c0 ? d.amount1() : d.amount0();
        int128 coinDelta = c0 ? d.amount0() : d.amount1();
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
