// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CreatorFeeHook} from "./CreatorFeeHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";


/// @title SweepAndBurn
/// @notice Flywheel module (Build Spec §4, "sweep and burn"): the coin's flywheel slice
///         buys the cheapest listed NFT of the collection and burns it. One instance per
///         coin; its address is the `flywheel` passed to CoinFactory.
///
///         Roles: `owner` (the collection's creator or a founders' multisig) approves
///         marketplaces and sets the price cap; `sweeper` (the platform keeper) picks the
///         listing and executes. The keeper cannot move JIG: the marketplace must be
///         approved and may not be any contract this module holds a balance in; the NFT
///         must not already be here before the call; JIG may only leave through the swap;
///         price <= cap; one sweep per COOLDOWN. The residual trust is that the keeper
///         could buy its own listing at the cap, which no contract can detect without a
///         floor oracle, so keep the cap close to the floor. The JIG sale is bounded to ~3%
///         past a reference price recorded by observe() in an earlier block.
contract SweepAndBurn is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint64 public constant COOLDOWN = 10 minutes;

    CreatorFeeHook public immutable hook;
    IERC20 public immutable jig;
    IERC721 public immutable collection;
    IPoolManager public immutable poolManager;
    address public immutable owner;
    address public immutable sweeper;
    PoolKey public jigPool; // ETH / JIG

    mapping(address => bool) public allowedMarket;
    uint256 public maxPriceWei;
    uint64 public lastSweep;
    uint256 public burned;
    /// @dev Reference price recorded in an earlier block, so a caller cannot set the bound in the same tx.
    uint160 public refSqrtPriceX96;
    uint64 public refBlock;
    uint64 public constant REF_MAX_AGE = 256; // blocks
    uint256 public constant MAX_IMPACT_BPS = 300;

    event Pulled(uint256 jig);
    event Swept(uint256 indexed tokenId, uint256 priceWei, uint256 jigSold);
    event MaxPriceSet(uint256 maxPriceWei);
    event MarketSet(address indexed market, bool allowed);

    error NotSweeper();
    error NotOwner();
    error ZeroAddress();
    error OverBudget();
    error OverMaxPrice();
    error NotReceived();
    error AlreadyHeld();
    error NotPoolManager();
    error MarketNotAllowed();
    error MarketplaceCallFailed();
    error JigMoved();
    error TooSoon();
    error NoReference();

    constructor(address hook_, address collection_, address owner_, address sweeper_, PoolKey memory jigPool_, uint256 maxPriceWei_) {
        if (hook_ == address(0) || collection_ == address(0) || owner_ == address(0) || sweeper_ == address(0)) revert ZeroAddress();
        hook = CreatorFeeHook(hook_);
        jig = hook.jig();
        poolManager = hook.poolManager();
        collection = IERC721(collection_);
        owner = owner_;
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
        if (msg.sender != owner) revert NotOwner();
        maxPriceWei = maxPriceWei_;
        emit MaxPriceSet(maxPriceWei_);
    }

    function setMarket(address market, bool allowed) external {
        if (msg.sender != owner) revert NotOwner();
        if (
            market == address(jig) || market == address(collection) || market == address(hook) || market == address(poolManager)
                || market == address(this) || market.code.length == 0
        ) revert MarketNotAllowed();
        allowedMarket[market] = allowed;
        emit MarketSet(market, allowed);
    }

    /// @notice Record the JIG/ETH pool price for a later sweep. Must be called in an earlier block than sweep().
    function observe() external {
        (uint160 sqrtP,,,) = poolManager.getSlot0(jigPool.toId());
        refSqrtPriceX96 = sqrtP;
        refBlock = uint64(block.number);
    }

    /// @notice Buy `tokenId` through an approved `marketplace` for `priceWei`, converting `jigToSell` JIG to ETH first, then burn it.
    ///         Pass jigToSell = 0 to spend ETH already held. A swap needs observe() from an earlier block.
    function sweep(address marketplace, bytes calldata data, uint256 tokenId, uint256 priceWei, uint256 jigToSell)
        external
        nonReentrant
    {
        if (msg.sender != sweeper) revert NotSweeper();
        if (!allowedMarket[marketplace]) revert MarketNotAllowed();
        if (priceWei > maxPriceWei) revert OverMaxPrice();
        if (block.timestamp < lastSweep + COOLDOWN) revert TooSoon();
        if (jigToSell > jig.balanceOf(address(this))) revert OverBudget();
        if (_heldHere(tokenId)) revert AlreadyHeld();

        uint256 jigSold;
        if (jigToSell > 0) {
            if (refBlock == 0 || block.number <= refBlock || block.number - refBlock > REF_MAX_AGE) revert NoReference();
            uint256 ethBefore = address(this).balance;
            jigSold = abi.decode(poolManager.unlock(abi.encode(jigToSell)), (uint256));
            if (address(this).balance - ethBefore < priceWei) revert OverBudget(); // this swap must cover the price
        }
        if (address(this).balance < priceWei) revert OverBudget();
        uint256 jigAfterSwap = jig.balanceOf(address(this));

        (bool ok,) = marketplace.call{value: priceWei}(data);
        if (!ok) revert MarketplaceCallFailed();
        if (jig.balanceOf(address(this)) != jigAfterSwap) revert JigMoved();
        if (!_heldHere(tokenId)) revert NotReceived();

        lastSweep = uint64(block.timestamp);
        collection.transferFrom(address(this), DEAD, tokenId);
        burned++;
        emit Swept(tokenId, priceWei, jigSold);
    }

    function _heldHere(uint256 tokenId) internal view returns (bool) {
        try collection.ownerOf(tokenId) returns (address o) {
            return o == address(this);
        } catch {
            return false;
        }
    }

    /// @dev Sell JIG for ETH on the JIG/ETH pool. JIG is currency1 (ETH is address 0), so this is oneForZero.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        (uint160 spot,,,) = poolManager.getSlot0(jigPool.toId());
        uint160 base = spot < refSqrtPriceX96 ? spot : refSqrtPriceX96; // selling JIG pushes the price up
        uint160 limit = uint160((uint256(base) * (10_000 + MAX_IMPACT_BPS / 2)) / 10_000);
        if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
        if (spot >= limit) return abi.encode(uint256(0));
        BalanceDelta d = poolManager.swap(
            jigPool, SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: limit}), ""
        );
        uint256 sold = uint256(uint128(-d.amount1()));
        if (sold > 0) {
            poolManager.sync(jigPool.currency1);
            jig.safeTransfer(address(poolManager), sold);
            poolManager.settle();
        }
        uint256 got = uint256(uint128(d.amount0()));
        if (got > 0) poolManager.take(jigPool.currency0, address(this), got);
        return abi.encode(sold);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
