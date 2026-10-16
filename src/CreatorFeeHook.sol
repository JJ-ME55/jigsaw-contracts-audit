// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
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
///   same transaction, so everything the hook ever holds is JIG. It then credits five
///   claimable balances: creator, flywheel module, platform, JIG pot and the LP-deepening
///   module. All payouts are pull (claim() / claimFor()), never push.
///
///   Fee split, in basis points of the fee: pot 300 and deepening 200 fixed; platform by
///   band (1% -> 2500, 2-3% -> 3000, 4-6% -> 3500, 7-10% -> 4000); the rest is the
///   creator+flywheel block (7000 / 6500 / 6000 / 5500), which the creator divides as they
///   like (default: flywheel 2000, creator the remainder). A creator's or flywheel's
///   earnings on a pool that sit unclaimed for RECYCLE_AFTER are folded back through the
///   split by anyone, with the creator+flywheel block going to the other side: a stale
///   creator balance feeds the flywheel, a stale flywheel balance feeds the pot. Recycling
///   is accounted per pool, so nobody can touch what an address earned elsewhere.
///
///   Anti-snipe: for SNIPE_WINDOW (seconds, pump-style) after launch the fee decays
///   linearly from SNIPE_FEE (60%) down to the chosen fee.
///
/// Address must carry exactly BEFORE_INITIALIZE | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA
/// (0x2844) in its low 14 bits.
contract CreatorFeeHook is IHooks, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    struct Config {
        address coin;
        address creator;
        address flywheel; // module that receives the flywheel slice; address(0) = creator
        uint24 feePips; // 10_000 (1%) .. 100_000 (10%)
        uint16 creatorBps; // creator's share of the fee; flywheel gets block - creatorBps
        PoolId id;
        int24 tickLower; // the seeded range: the nested conversion never sells outside it
        int24 tickUpper;
        uint64 launchedAt;
        bool coinIs0;
        bool registered;
        bool seeded; // true once the factory has seeded: no other liquidity, ever (swarm audit 3)
    }

    uint24 public constant MIN_FEE = 10_000;
    uint24 public constant MAX_FEE = 100_000;
    uint24 public constant SNIPE_FEE = 600_000;
    uint64 public constant SNIPE_WINDOW = 10 seconds;
    uint64 public constant RECYCLE_AFTER = 7 days;
    uint256 internal constant PIPS = 1_000_000;

    uint16 public constant DEFAULT_FLYWHEEL_BPS = 2000;
    uint16 public constant POT_BPS = 300;
    uint16 public constant DEEPEN_BPS = 200;

    IPoolManager public immutable poolManager;
    IERC20 public immutable jig;
    address public immutable owner;
    address public factory; // set once by the owner after the factory is deployed (hook and factory reference each other)
    address public immutable platform;
    address public immutable pot;
    address public deepening; // LP-deepening module; the pot until setDeepening() binds it (once)

    mapping(PoolId => Config) public pools;
    mapping(address => uint256) public claimable; // JIG owed, by recipient
    // Per-pool recycle ledger: what creator/flywheel earned on this pool since their last full claim.
    // claimEpoch bumps on every claim/claimFor; entries from an older epoch count as zero.
    // Credits are bucketed by day so recycle() can take exactly the part that is RECYCLE_AFTER old and nothing
    // younger: a fresh credit can neither block the stale part (round 2) nor be swept with it (round 3).
    struct Chunk { uint64 day; uint128 amount; }
    struct Earned { uint64 epoch; uint64 head; Chunk[] chunks; }
    mapping(PoolId => mapping(address => Earned)) internal earned;
    mapping(address => uint64) public claimEpoch;
    uint16 public constant DEFAULT_SHARE = type(uint16).max; // register sentinel: default split
    mapping(PoolId => uint256) public pendingCoin; // coin claims not yet converted (partial fills), per pool
    uint256 public totalClaimable;
    bool private _converting;

    event PoolRegistered(PoolId indexed id, address indexed coin, address indexed creator, uint24 feePips, address flywheel, uint16 creatorBps);
    event CreatorShareSet(PoolId indexed id, uint16 creatorBps);
    event Recycled(PoolId indexed id, address indexed from, uint256 amount);
    event FeeLowered(PoolId indexed id, uint24 feePips);
    event FactorySet_(address factory);
    event DeepeningSet_(address deepening);
    event FeeTaken(PoolId indexed id, uint256 jigAmount, uint24 feePips);
    event Claimed(address indexed to, uint256 amount);

    error NotPoolManager();
    error NotFactory();
    error NotOwner();
    error FactorySet();
    error DeepeningSet();
    error NotCreator();
    error NotRegistered();
    error AlreadyRegistered();
    error BadPool();
    error BadFee();
    error BadShare();
    error NotStale();
    error BadFlywheel();
    error HookNotImplemented();
    error LiquidityLocked();
    error ExactOutputSell();

    constructor(address poolManager_, address jig_, address owner_, address platform_, address pot_) {
        poolManager = IPoolManager(poolManager_);
        jig = IERC20(jig_);
        owner = owner_;
        platform = platform_;
        pot = pot_;
        deepening = pot_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
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

    /// @notice Bind the LP-deepening module. Once only; until then the slice accrues to the pot.
    function setDeepening(address deepening_) external {
        if (msg.sender != owner) revert NotOwner();
        if (deepening != pot || deepening_ == address(0)) revert DeepeningSet();
        deepening = deepening_;
        emit DeepeningSet_(deepening_);
    }

    /// @notice Bind the factory. Once only.
    function setFactory(address factory_) external {
        if (msg.sender != owner) revert NotOwner();
        if (factory != address(0) || factory_ == address(0)) revert FactorySet();
        factory = factory_;
        emit FactorySet_(factory_);
    }

    /// @notice Called by the factory before it initialises the pool.
    function register(PoolKey calldata key, address creator, address flywheel, uint24 feePips, uint16 creatorBps, int24 tickLower, int24 tickUpper) external {
        if (msg.sender != factory) revert NotFactory();
        if (
            flywheel == platform || flywheel == pot || flywheel == deepening || flywheel == address(this)
                || flywheel == address(poolManager) || flywheel == factory
        ) revert BadFlywheel();
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
        uint16 block_ = creatorBlockBps(feePips);
        if (creatorBps == DEFAULT_SHARE) creatorBps = block_ - DEFAULT_FLYWHEEL_BPS;
        if (creatorBps > block_) revert BadShare();
        pools[id] = Config({
            coin: coinIs0 ? c0 : c1,
            creator: creator,
            flywheel: flywheel,
            feePips: feePips,
            creatorBps: creatorBps,
            id: id,
            tickLower: tickLower,
            tickUpper: tickUpper,
            launchedAt: uint64(block.timestamp),
            coinIs0: coinIs0,
            registered: true,
            seeded: false
        });
        emit PoolRegistered(id, coinIs0 ? c0 : c1, creator, feePips, flywheel, creatorBps);
    }

    /// @notice The creator may move the slider between themselves and the flywheel at any time.
    function setCreatorShare(PoolKey calldata key, uint16 creatorBps) external {
        Config storage c = pools[key.toId()];
        if (!c.registered) revert NotRegistered();
        if (msg.sender != c.creator) revert NotCreator();
        if (creatorBps > creatorBlockBps(c.feePips)) revert BadShare();
        c.creatorBps = creatorBps;
        emit CreatorShareSet(key.toId(), creatorBps);
    }

    /// @notice The creator may lower the fee, never raise it.
    function lowerFee(PoolKey calldata key, uint24 feePips) external {
        Config storage c = pools[key.toId()];
        if (!c.registered) revert NotRegistered();
        if (msg.sender != c.creator) revert NotCreator();
        if (feePips < MIN_FEE || feePips >= c.feePips || feePips % MIN_FEE != 0) revert BadFee();
        c.feePips = feePips;
        uint16 block_ = creatorBlockBps(feePips);
        if (c.creatorBps > block_) c.creatorBps = block_; // a lower fee widens the block; never narrows it below the slider
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
        if (feePips <= 10_000) return 2500;
        if (feePips <= 30_000) return 3000;
        if (feePips <= 60_000) return 3500;
        return 4000;
    }

    /// @notice The creator+flywheel block: everything after platform, pot and deepening.
    function creatorBlockBps(uint24 feePips) public pure returns (uint16) {
        return 10_000 - platformBps(feePips) - POT_BPS - DEEPEN_BPS;
    }

    /// @notice Fold what `from` earned on this pool and left unclaimed for RECYCLE_AFTER back through the split.
    ///         Anyone may call. Only this pool's creator or flywheel is recyclable, only for what they earned here,
    ///         and the creator+flywheel block goes to the other side (creator's stale money feeds the flywheel,
    ///         the flywheel's stale money feeds the pot), so recycling can never pay the party that let it go stale.
    /// @notice The factory calls this once its seed position is minted. From then on the pool accepts no liquidity
    ///         from anyone: an LP band inside the range would trade coin for JIG at spot with no fee and no anti-snipe.
    function seal(PoolKey calldata key) external {
        if (msg.sender != factory) revert NotFactory();
        Config storage c = pools[key.toId()];
        if (!c.registered) revert NotRegistered();
        c.seeded = true;
    }

    function recycle(PoolKey calldata key, address from) external nonReentrant returns (uint256 amount) {
        PoolId id = key.toId();
        Config storage c = pools[id];
        if (!c.registered) revert NotRegistered();
        address fly = c.flywheel == address(0) ? c.creator : c.flywheel;
        if (from != c.creator && from != fly) revert NotStale();
        Earned storage e = earned[id][from];
        if (e.epoch != claimEpoch[from]) revert NotStale();
        uint64 cutoff = uint64(block.timestamp / 1 days) - uint64(RECYCLE_AFTER / 1 days); // days at or before this are stale
        uint256 i = e.head;
        uint256 n = e.chunks.length;
        while (i < n && e.chunks[i].day <= cutoff) {
            amount += e.chunks[i].amount;
            i++;
        }
        if (amount == 0) revert NotStale();
        e.head = uint64(i);
        if (amount > claimable[from]) amount = claimable[from];
        claimable[from] -= amount;
        totalClaimable -= amount;
        uint256 potA = (amount * POT_BPS) / 10_000;
        uint256 deep = (amount * DEEPEN_BPS) / 10_000;
        uint256 plat = (amount * platformBps(c.feePips)) / 10_000;
        uint256 rest = amount - potA - deep - plat;
        _credit(pot, potA);
        _credit(deepening, deep);
        _credit(platform, plat);
        if (from == c.creator && fly != c.creator) _creditEarned(id, fly, rest);
        else _credit(pot, rest);
        totalClaimable += amount;
        emit Recycled(id, from, amount);
    }

    /// @notice What `recycle(key, who)` would fold right now (credits at least RECYCLE_AFTER old), and what is younger.
    function recyclable(PoolKey calldata key, address who) external view returns (uint256 stale, uint256 fresh) {
        Earned storage e = earned[key.toId()][who];
        if (e.epoch != claimEpoch[who]) return (0, 0);
        uint64 cutoff = uint64(block.timestamp / 1 days) - uint64(RECYCLE_AFTER / 1 days);
        for (uint256 i = e.head; i < e.chunks.length; i++) {
            if (e.chunks[i].day <= cutoff) stale += e.chunks[i].amount;
            else fresh += e.chunks[i].amount;
        }
    }

    // ---------------- claims ----------------

    function claim() external nonReentrant returns (uint256 amount) {
        return _claim(msg.sender);
    }

    /// @notice Pay `to` what it is owed. Anyone may call; funds only ever go to the credited address.
    ///         Needed for recipients that cannot call claim() themselves (PotVault, deepening).
    function claimFor(address to) external nonReentrant returns (uint256 amount) {
        return _claim(to);
    }

    function _claim(address to) internal returns (uint256 amount) {
        amount = claimable[to];
        claimable[to] = 0;
        totalClaimable -= amount;
        claimEpoch[to]++; // per-pool recycle entries from before this claim no longer count
        if (amount > 0) poolManager.unlock(abi.encode(to, amount));
        emit Claimed(to, amount);
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

    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external
        override
        returns (bytes4, int128)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (_converting) return (IHooks.afterSwap.selector, 0); // belt and braces: v4's Hooks.afterSwap already skips a hook's own swaps (noSelfCall)
        PoolId id = key.toId();
        Config storage c = pools[id];
        if (!c.registered) revert NotRegistered();

        // The specified currency is the input on exact-input swaps and the output on exact-output swaps.
        bool specifiedIs0 = params.zeroForOne == (params.amountSpecified < 0);
        int128 unspec = specifiedIs0 ? delta.amount1() : delta.amount0();
        uint256 abs = unspec < 0 ? uint256(uint128(-unspec)) : uint256(uint128(unspec));
        uint24 feePips = sender == factory ? c.feePips : currentFee(id); // the creator's dev buy at launch is not a snipe
        // Exact-input: the unspecified currency is the output, fee = f * output (swapper keeps 1 - f).
        // Exact-output: the unspecified currency is the input, charged on top; scale so the effective rate matches.
        uint256 fee = params.amountSpecified < 0 ? (abs * feePips) / PIPS : (abs * feePips) / (PIPS - feePips);
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        // Hold the fee as an ERC-6909 claim inside the PoolManager. No real tokens move until claim(),
        // so this works even before the swapper's input has been settled.
        Currency feeCurrency = specifiedIs0 ? key.currency1 : key.currency0;
        poolManager.mint(address(this), feeCurrency.toId(), fee);

        uint256 jigAmount = fee;
        bool feeIsCoin = Currency.unwrap(feeCurrency) == c.coin;
        // An exact-output sell (exact JIG out, coin in) would take its fee in coin and sell it at the price the
        // seller's own trade just left, about half the exact-input fee on a large unwind (swarm audit 2). Refuse it;
        // routers fall back to exact-input, which pays f of the JIG output directly.
        if (feeIsCoin && params.amountSpecified > 0) revert ExactOutputSell();
        if (feeIsCoin) jigAmount = _sellCoinForJig(key, c, fee);

        hookData;
        _split(c, jigAmount);
        emit FeeTaken(id, jigAmount, feePips);
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    /// @dev Sell `amount` of the coin into the same pool for JIG, inside the current unlock. The sale never leaves the
    ///      launch range: selling the coin pushes the price toward the empty side, and anything parked there (a dust JIG
    ///      order below the range) would otherwise buy the whole fee for nothing. If the price already sits at the range
    ///      edge, the fee waits as pendingCoin and is converted on a later swap that has moved the price back inside.
    function _sellCoinForJig(PoolKey calldata key, Config storage c, uint256 amount) internal returns (uint256 jigOut) {
        PoolId id = c.id;
        bool coinIs0 = c.coinIs0;
        amount += pendingCoin[id]; // retry anything a previous partial fill left behind
        uint160 limit = coinIs0 ? TickMath.getSqrtPriceAtTick(c.tickLower) : TickMath.getSqrtPriceAtTick(c.tickUpper);
        (uint160 spot,,,) = poolManager.getSlot0(id);
        if (coinIs0 ? spot <= limit : spot >= limit) {
            pendingCoin[id] = amount; // nothing to sell into inside the range right now
            return 0;
        }
        _converting = true;
        BalanceDelta d = poolManager.swap(
            key, SwapParams({zeroForOne: coinIs0, amountSpecified: -int256(amount), sqrtPriceLimitX96: limit}), ""
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
        // if the pool could not absorb the whole amount, the remainder stays as coin claims and is retried next time
        pendingCoin[id] = amount - owed;
    }

    function _split(Config storage c, uint256 amount) internal {
        uint256 potA = (amount * POT_BPS) / 10_000;
        uint256 deep = (amount * DEEPEN_BPS) / 10_000;
        uint256 plat = (amount * platformBps(c.feePips)) / 10_000;
        uint256 creator = (amount * c.creatorBps) / 10_000;
        uint256 fly = amount - potA - deep - plat - creator;

        PoolId id = _idOf(c);
        _creditEarned(id, c.flywheel == address(0) ? c.creator : c.flywheel, fly);
        _credit(pot, potA);
        _credit(deepening, deep);
        _credit(platform, plat);
        _creditEarned(id, c.creator, creator);
        totalClaimable += amount;
    }

    /// @dev Credit a creator/flywheel recipient and record it on the pool's recycle ledger.
    function _creditEarned(PoolId id, address to, uint256 amount) internal {
        if (amount == 0) return;
        _credit(to, amount);
        Earned storage e = earned[id][to];
        if (e.epoch != claimEpoch[to]) { e.epoch = claimEpoch[to]; delete e.chunks; e.head = 0; }
        uint64 day = uint64(block.timestamp / 1 days);
        uint256 n = e.chunks.length;
        if (n > e.head && e.chunks[n - 1].day == day) e.chunks[n - 1].amount += uint128(amount);
        else e.chunks.push(Chunk({day: day, amount: uint128(amount)}));
    }

    function _idOf(Config storage c) internal view returns (PoolId) {
        return c.id;
    }

    function _credit(address to, uint256 amount) internal {
        if (amount > 0) claimable[to] += amount;
    }

    // ---------------- unused hooks ----------------

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Config storage c = pools[key.toId()];
        if (!c.registered || c.seeded) revert LiquidityLocked();
        return IHooks.beforeAddLiquidity.selector;
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
