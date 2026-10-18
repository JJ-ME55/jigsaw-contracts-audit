// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CreatorFeeHook} from "./CreatorFeeHook.sol";

/// @title LPDeepening
/// @notice The deepening slice of every creator-coin fee (Build Spec §3c) becomes
///         permanent JIG/ETH liquidity. `run()` pulls the module's JIG from the hook,
///         sells half for ETH on the JIG/ETH pool, and adds both as full-range liquidity
///         to a position this contract holds forever. There is no function to remove
///         liquidity or transfer the position. LP fees it earns go half to the team wallet, half to the pot, like the JIG pool's.
///         Shared: one instance, bound to the hook as `deepening`. Keeper-only runs at times
///         the back end chooses; each run uses the whole balance with a keeper-supplied minimum out.
contract LPDeepening is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    CreatorFeeHook public immutable hook;
    IERC20 public immutable jig;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable posm;
    IAllowanceTransfer public immutable permit2;
    address public immutable pot;
    address public immutable platform;
    uint16 public constant TEAM_BPS = 5000; // the deepening position's fees are JIG-pool fees: same 50/50 team/pot as JIGLaunch (Jj, 15 Oct)
    uint256 public platformOwedEth; // team ETH whose push failed; withdrawn by the platform
    PoolKey public jigPool; // ETH / JIG

    address public keeper; // the platform (the Safe) can replace it if the key is lost or leaks (final audit, 17 Oct)

    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    uint256 public tokenId; // 0 until the first deepening
    uint256 public totalJigAdded;
    uint256 public totalEthAdded;

    event Deepened(uint256 jigSold, uint256 ethGot, uint256 jigAdded, uint256 ethAdded, uint128 liquidity);
    event FeesCollected(uint256 eth, uint256 jig);
    event KeeperSet(address keeper);

    error NotPoolManager();
    error ZeroAddress();
    error Nothing();
    error PayoutFailed();
    error NotPlatformAddr();
    error NotKeeper();
    error TooLittleOut();

    constructor(address hook_, address posm_, address permit2_, PoolKey memory jigPool_, address keeper_) {
        if (hook_ == address(0) || posm_ == address(0) || permit2_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        hook = CreatorFeeHook(hook_);
        jig = hook.jig();
        poolManager = hook.poolManager();
        pot = hook.pot();
        platform = hook.platform();
        posm = IPositionManager(posm_);
        permit2 = IAllowanceTransfer(permit2_);
        jigPool = jigPool_;
        int24 spacing = jigPool_.tickSpacing;
        tickLower = (TickMath.MIN_TICK / spacing) * spacing;
        tickUpper = (TickMath.MAX_TICK / spacing) * spacing;
    }

    /// @notice Pull this module's slice from the hook into its balance. Anyone may call.
    function pull() external nonReentrant returns (uint256 amount) {
        amount = hook.claim();
    }

    /// @notice Pull the slice, sell half for ETH, add both to the locked full-range position. Keeper only.
    /// @notice The platform (the Safe) replaces the keeper.
    function setKeeper(address keeper_) external {
        if (msg.sender != platform) revert NotPlatformAddr();
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @param minEthOut the least ETH the keeper will accept for the half it sells (off-chain quote minus tolerance)
    function run(uint256 minEthOut) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        hook.claim();
        uint256 amount = jig.balanceOf(address(this));
        if (amount == 0) revert Nothing();
        uint256 half = amount / 2;
        uint256 ethBefore = address(this).balance;
        poolManager.unlock(abi.encode(half));
        uint256 ethGot = address(this).balance - ethBefore;
        if (ethGot < minEthOut || ethGot == 0) revert TooLittleOut();
        // pay out accrued LP fees now, after our own sale has paid the position its share: INCREASE_LIQUIDITY
        // would otherwise net them into the locked position (swarm audits 2 and 3)
        if (tokenId != 0) _collectFees();
        uint256 jigLeft = amount - half; // only this run's other half goes in; the rest waits
        uint256 eth = address(this).balance - platformOwedEth; // ETH booked for the team is not working capital

        (uint160 sqrtP,,,) = poolManager.getSlot0(jigPool.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), eth, jigLeft
        );
        if (liquidity == 0) revert Nothing();

        jig.forceApprove(address(permit2), jigLeft);
        permit2.approve(address(jig), address(posm), uint160(jigLeft), uint48(block.timestamp + 1 hours));

        bytes memory actions;
        bytes[] memory params = new bytes[](3);
        if (tokenId == 0) {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params[0] = abi.encode(jigPool, tickLower, tickUpper, liquidity, uint128(eth), uint128(jigLeft), address(this), bytes(""));
            tokenId = posm.nextTokenId();
        } else {
            actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params[0] = abi.encode(tokenId, liquidity, uint128(eth), uint128(jigLeft), bytes(""));
        }
        params[1] = abi.encode(jigPool.currency0, jigPool.currency1);
        params[2] = abi.encode(jigPool.currency0, address(this)); // refund unused ETH
        uint256 ethBeforeAdd = address(this).balance;
        uint256 jigBeforeAdd = jig.balanceOf(address(this));
        posm.modifyLiquidities{value: eth}(abi.encode(actions, params), block.timestamp);
        uint256 ethAdded = ethBeforeAdd - address(this).balance;
        uint256 jigAdded = jigBeforeAdd - jig.balanceOf(address(this));
        totalEthAdded += ethAdded;
        totalJigAdded += jigAdded;
        emit Deepened(half, ethGot, jigAdded, ethAdded, liquidity);
        // jigLeft not consumed by the position stays in the module for the next run
    }

    /// @notice Collect the position's LP fees: TEAM_BPS to platform, the rest to the pot. Liquidity is untouched.
    ///         Collected fees are kept separate from the module's working balance by paying out in the same call.
    function collectFees() external nonReentrant {
        if (tokenId == 0) revert Nothing();
        _collectFees();
    }

    function _collectFees() internal {
        uint256 ethBefore = address(this).balance;
        uint256 jigBefore = jig.balanceOf(address(this));
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(jigPool.currency0, jigPool.currency1, address(this));
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        uint256 eth = address(this).balance - ethBefore;
        uint256 j = jig.balanceOf(address(this)) - jigBefore;
        if (eth > 0) {
            uint256 team = (eth * TEAM_BPS) / 10_000;
            (bool b,) = pot.call{value: eth - team}("");
            if (!b) revert PayoutFailed();
            (bool a,) = platform.call{value: team}("");
            if (!a) platformOwedEth += team;
        }
        if (j > 0) {
            uint256 team = (j * TEAM_BPS) / 10_000;
            jig.safeTransfer(platform, team);
            jig.safeTransfer(pot, j - team);
        }
        emit FeesCollected(eth, j);
    }

    /// @notice Withdraw team ETH that could not be pushed. Platform only.
    function withdrawPlatform() external {
        if (msg.sender != platform) revert NotPlatformAddr();
        uint256 amt = platformOwedEth;
        platformOwedEth = 0;
        (bool ok,) = platform.call{value: amt}("");
        if (!ok) revert PayoutFailed();
    }

    /// @dev Sell `amount` JIG for ETH on the JIG/ETH pool (JIG is currency1).
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        BalanceDelta d = poolManager.swap(
            jigPool, SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), ""
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
