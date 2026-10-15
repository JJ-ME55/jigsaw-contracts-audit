// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CreatorFeeHook
/// @notice The one shared fee hook for every creator coin (Economics v3 §5, Addendum A, Build Spec §5).
///
///   Every creator-coin pool is coin/JIG, LP fee 0, with this hook. On every swap the
///   hook takes the creator's chosen fee (1% to 10%, set at launch, lower-only) from the
///   swap's unspecified currency. If that is the coin, the hook sells it for JIG in the
///   same transaction, so everything the hook ever holds is JIG. It then credits six
///   claimable balances: creator, flywheel module, launch referral, trade referral,
///   platform, JIG pot, plus the LP-deepening slice. All payouts are pull (claim()),
///   never push.
///
///   Fee split, in basis points of the fee: flywheel 2000, launch referral 1000, trade
///   referral 1000, pot 300, deepening 200, platform by band (1% -> 1500, 2-3% -> 2000,
///   4-6% -> 2500, 7-10% -> 3000), creator the remainder. Referrals default to platform.
///
///   Anti-snipe: for SNIPE_WINDOW after launch the fee decays linearly from SNIPE_FEE
///   (60%) down to the chosen fee.
///
/// Address must carry exactly BEFORE_INITIALIZE | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA
/// (0x2044) in its low 14 bits.
contract CreatorFeeHook is IHooks, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    struct Config {
        address coin;
        address creator;
        address flywheel; // module that receives the flywheel slice; address(0) = creator
        address launchReferral; // address(0) = platform
        uint24 feePips; // 10_000 (1%) .. 100_000 (10%)
        uint64 launchedAt;
        bool coinIs0;
        bool registered;
    }

    uint24 public constant MIN_FEE = 10_000;
    uint24 public constant MAX_FEE = 100_000;
    uint24 public constant SNIPE_FEE = 600_000;
    uint64 public constant SNIPE_WINDOW = 10 minutes;
    uint256 internal constant PIPS = 1_000_000;

    uint16 public constant FLYWHEEL_BPS = 2000;
    uint16 public constant LAUNCH_REF_BPS = 1000;
    uint16 public constant TRADE_REF_BPS = 1000;
    uint16 public constant POT_BPS = 300;
    uint16 public constant DEEPEN_BPS = 200;

    IPoolManager public immutable poolManager;
    IERC20 public immutable jig;
    address public immutable owner;
    address public factory; // set once by the owner after the factory is deployed (hook and factory reference each other)
    address public immutable platform;
    address public immutable pot;
    address public immutable deepening; // LP-deepening module, or the pot until it exists

    mapping(PoolId => Config) public pools;
    mapping(address => uint256) public claimable; // JIG owed, by recipient
    uint256 public totalClaimable;
    bool private _converting;

    event PoolRegistered(PoolId indexed id, address indexed coin, address indexed creator, uint24 feePips, address flywheel, address launchReferral);
    event FeeLowered(PoolId indexed id, uint24 feePips);
    event FactorySet_(address factory);
    event FeeTaken(PoolId indexed id, address indexed tradeReferral, uint256 jigAmount, uint24 feePips);
    event Claimed(address indexed to, uint256 amount);

    error NotPoolManager();
    error NotFactory();
    error NotOwner();
    error FactorySet();
    error NotCreator();
    error NotRegistered();
    error AlreadyRegistered();
    error BadPool();
    error BadFee();
    error HookNotImplemented();

    constructor(address poolManager_, address jig_, address owner_, address platform_, address pot_, address deepening_) {
        poolManager = IPoolManager(poolManager_);
        jig = IERC20(jig_);
        owner = owner_;
        platform = platform_;
        pot = pot_;
        deepening = deepening_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------- registration ----------------

    /// @notice Bind the factory. Once only.
    function setFactory(address factory_) external {
        if (msg.sender != owner) revert NotOwner();
        if (factory != address(0) || factory_ == address(0)) revert FactorySet();
        factory = factory_;
        emit FactorySet_(factory_);
    }

    /// @notice Called by the factory before it initialises the pool.
    function register(PoolKey calldata key, address creator, address flywheel, address launchReferral, uint24 feePips) external {
        if (msg.sender != factory) revert NotFactory();
        if (feePips < MIN_FEE || feePips > MAX_FEE || feePips % MIN_FEE != 0) revert BadFee();
        if (address(key.hooks) != address(this) || key.fee != 0) revert BadPool();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool coinIs0;
        if (c1 == address(jig) && c0 != address(0)) coinIs0 = true;
        else if (c0 == address(jig)) coinIs0 = false;
        else revert BadPool();
        PoolId id = key.toId();
        if (pools[id].registered) revert AlreadyRegistered();
        pools[id] = Config({
            coin: coinIs0 ? c0 : c1,
            creator: creator,
            flywheel: flywheel,
            launchReferral: launchReferral,
            feePips: feePips,
            launchedAt: uint64(block.timestamp),
            coinIs0: coinIs0,
            registered: true
        });
        emit PoolRegistered(id, coinIs0 ? c0 : c1, creator, feePips, flywheel, launchReferral);
    }

    /// @notice The creator may lower the fee, never raise it.
    function lowerFee(PoolKey calldata key, uint24 feePips) external {
        Config storage c = pools[key.toId()];
        if (!c.registered) revert NotRegistered();
        if (msg.sender != c.creator) revert NotCreator();
        if (feePips < MIN_FEE || feePips >= c.feePips || feePips % MIN_FEE != 0) revert BadFee();
        c.feePips = feePips;
        emit FeeLowered(key.toId(), feePips);
    }

    /// @notice Fee in pips a swap on this pool pays right now (anti-snipe decay included).
    function currentFee(PoolId id) public view returns (uint24) {
        Config storage c = pools[id];
        uint256 elapsed = block.timestamp - c.launchedAt;
        if (elapsed >= SNIPE_WINDOW) return c.feePips;
        // linear decay from SNIPE_FEE to feePips over the window
        return uint24(SNIPE_FEE - (uint256(SNIPE_FEE - c.feePips) * elapsed) / SNIPE_WINDOW);
    }

    function platformBps(uint24 feePips) public pure returns (uint16) {
        if (feePips <= 10_000) return 1500;
        if (feePips <= 30_000) return 2000;
        if (feePips <= 60_000) return 2500;
        return 3000;
    }

    // ---------------- claims ----------------

    function claim() external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender];
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        if (amount > 0) poolManager.unlock(abi.encode(msg.sender, amount));
        emit Claimed(msg.sender, amount);
    }

    /// @dev Only reached from claim(): burn JIG claims and send real JIG to the claimant.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        Currency jigC = Currency.wrap(address(jig));
        poolManager.burn(address(this), jigC.toId(), amount);
        poolManager.take(jigC, to, amount);
        return "";
    }

    /// @notice JIG held for all claimants, as ERC-6909 claims in the PoolManager.
    function heldJig() external view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(address(jig)).toId());
    }

    // ---------------- hooks ----------------

    function beforeInitialize(address, PoolKey calldata key, uint160) external view override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!pools[key.toId()].registered) revert NotRegistered();
        return IHooks.beforeInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external
        override
        returns (bytes4, int128)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (_converting) return (IHooks.afterSwap.selector, 0);
        PoolId id = key.toId();
        Config storage c = pools[id];
        if (!c.registered) revert NotRegistered();

        // The specified currency is the input on exact-input swaps and the output on exact-output swaps.
        bool specifiedIs0 = params.zeroForOne == (params.amountSpecified < 0);
        int128 unspec = specifiedIs0 ? delta.amount1() : delta.amount0();
        uint256 abs = unspec < 0 ? uint256(uint128(-unspec)) : uint256(uint128(unspec));
        uint24 feePips = currentFee(id);
        uint256 fee = (abs * feePips) / PIPS;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        // Hold the fee as an ERC-6909 claim inside the PoolManager. No real tokens move until claim(),
        // so this works even before the swapper's input has been settled.
        Currency feeCurrency = specifiedIs0 ? key.currency1 : key.currency0;
        poolManager.mint(address(this), feeCurrency.toId(), fee);

        uint256 jigAmount = fee;
        bool feeIsCoin = Currency.unwrap(feeCurrency) == c.coin;
        if (feeIsCoin) jigAmount = _sellCoinForJig(key, c.coinIs0, fee);

        address tradeRef = hookData.length >= 32 ? abi.decode(hookData, (address)) : address(0);
        _split(c, jigAmount, tradeRef);
        emit FeeTaken(id, tradeRef, jigAmount, feePips);
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    /// @dev Sell `amount` of the coin into the same pool for JIG, inside the current unlock.
    function _sellCoinForJig(PoolKey calldata key, bool coinIs0, uint256 amount) internal returns (uint256 jigOut) {
        _converting = true;
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: coinIs0,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: coinIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _converting = false;
        Currency coin = coinIs0 ? key.currency0 : key.currency1;
        Currency jigC = coinIs0 ? key.currency1 : key.currency0;
        int128 coinDelta = coinIs0 ? d.amount0() : d.amount1();
        int128 jigDelta = coinIs0 ? d.amount1() : d.amount0();
        // pay the coin we owe by burning our coin claims; keep the JIG we are owed as JIG claims
        uint256 owed = uint256(uint128(-coinDelta));
        poolManager.burn(address(this), coin.toId(), owed);
        jigOut = uint256(uint128(jigDelta));
        poolManager.mint(address(this), jigC.toId(), jigOut);
        // if the pool could not absorb the whole amount, the remainder stays as coin claims (not credited)
    }

    function _split(Config storage c, uint256 amount, address tradeRef) internal {
        uint256 fly = (amount * FLYWHEEL_BPS) / 10_000;
        uint256 lref = (amount * LAUNCH_REF_BPS) / 10_000;
        uint256 tref = (amount * TRADE_REF_BPS) / 10_000;
        uint256 potA = (amount * POT_BPS) / 10_000;
        uint256 deep = (amount * DEEPEN_BPS) / 10_000;
        uint256 plat = (amount * platformBps(c.feePips)) / 10_000;
        uint256 creator = amount - fly - lref - tref - potA - deep - plat;

        _credit(c.flywheel == address(0) ? c.creator : c.flywheel, fly);
        _credit(c.launchReferral == address(0) ? platform : c.launchReferral, lref);
        _credit(tradeRef == address(0) ? platform : tradeRef, tref);
        _credit(pot, potA);
        _credit(deepening, deep);
        _credit(platform, plat);
        _credit(c.creator, creator);
        totalClaimable += amount;
    }

    function _credit(address to, uint256 amount) internal {
        if (amount > 0) claimable[to] += amount;
    }

    // ---------------- unused hooks ----------------

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) external pure override returns (bytes4, BeforeSwapDelta, uint24) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }
}
