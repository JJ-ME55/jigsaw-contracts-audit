// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title JIGLaunch
/// @notice One-shot fair launch of the JIG/ETH Uniswap v4 pool (spec 2).
///         Holds 90% of JIG supply from birth. `launch` creates the pool, seeds it
///         single-sided with every JIG it holds, and mints the LP position to this
///         contract. There is no function to transfer the position or remove
///         liquidity, so the LP is locked forever. LP fees can be collected by
///         anyone: TEAM_BPS of them go to the platform wallet, the rest to the pot vault
///         (Jj, 15 Oct: some of the JIG pool's 1.5% straight to the team, the rest to the pot).
///
///         Single-sided: the range sits entirely below the starting price
///         (tickLower < tickUpper <= startTick), so the position holds JIG only.
///         As buyers pay ETH for JIG the price moves down into the range and the
///         position accrues ETH.
contract JIGLaunch {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPositionManager public immutable posm;
    IPoolManager public immutable poolManager;
    IAllowanceTransfer public immutable permit2;
    address public immutable launcher;
    address public immutable potVault;
    address public immutable platform;
    uint16 public constant TEAM_BPS = 5000; // half of collected fees to the team, half to the pot (Jj, 15 Oct)

    IERC20 public jig;
    PoolKey public poolKey;
    uint256 public tokenId;
    bool public launched;

    event Launched(uint256 indexed tokenId, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 jigSeeded);
    event FeesCollected(uint256 ethTotal, uint256 jigTotal);

    error NotLauncher();
    error AlreadyLaunched();
    error NotLaunched();
    error JigNotSet();
    error RangeNotBelowPrice();
    error ZeroAddress();
    error PayoutFailed();
    error PriceMismatch();

    constructor(address posm_, address permit2_, address launcher_, address potVault_, address platform_) {
        if (posm_ == address(0) || permit2_ == address(0) || launcher_ == address(0) || potVault_ == address(0) || platform_ == address(0)) revert ZeroAddress();
        platform = platform_;
        posm = IPositionManager(posm_);
        poolManager = IPositionManager(posm_).poolManager();
        permit2 = IAllowanceTransfer(permit2_);
        launcher = launcher_;
        potVault = potVault_;
    }

    /// @notice Set once, by the launcher, after JIG is deployed with this contract as the launch recipient.
    function setJig(address jig_) external {
        if (msg.sender != launcher) revert NotLauncher();
        if (address(jig) != address(0)) revert AlreadyLaunched();
        if (jig_ == address(0)) revert ZeroAddress();
        jig = IERC20(jig_);
    }

    /// @param fee pool fee in hundredths of a bip (10_000 = 1%)
    /// @param tickSpacing pool tick spacing
    /// @param hooks hook address, address(0) for none. The anti-snipe hook is phase 2.
    /// @param sqrtPriceX96 starting price as sqrt(JIG per ETH) * 2^96
    /// @param tickLower bottom of the seeded range (multiple of tickSpacing)
    /// @param tickUpper top of the seeded range; must be <= the starting tick
    function launch(uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper)
        external
        returns (uint256 id)
    {
        if (msg.sender != launcher) revert NotLauncher();
        if (launched) revert AlreadyLaunched();
        if (address(jig) == address(0)) revert JigNotSet();
        launched = true;

        int24 startTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        if (tickUpper > startTick || tickLower >= tickUpper) revert RangeNotBelowPrice();

        // ETH is currency0 (address 0 sorts first), JIG is currency1.
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(jig)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
        // Initialise directly so a revert surfaces (PositionManager.initializePool swallows them), then verify.
        poolManager.initialize(poolKey, sqrtPriceX96);
        (uint160 actual,,,) = poolManager.getSlot0(poolKey.toId());
        if (actual != sqrtPriceX96) revert PriceMismatch();

        uint256 amount = jig.balanceOf(address(this));
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount
        );

        jig.forceApprove(address(permit2), amount);
        permit2.approve(address(jig), address(posm), uint160(amount), uint48(block.timestamp + 1 hours));

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, uint128(0), uint128(amount), address(this), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        id = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        tokenId = id;

        emit Launched(id, sqrtPriceX96, tickLower, tickUpper, liquidity, amount - jig.balanceOf(address(this)));
    }

    /// @notice Collect accrued LP fees and split them: TEAM_BPS to platform, the rest to the pot. Anyone may call. Liquidity is untouched.
    function collectFees() external {
        if (!launched) revert NotLaunched();
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        emit FeesCollected(address(this).balance, jig.balanceOf(address(this)));
        _payout();
    }

    /// @dev Split whatever this contract holds of ETH and JIG: TEAM_BPS to platform, the rest to the pot.
    function _payout() internal {
        uint256 eth = address(this).balance;
        if (eth > 0) {
            uint256 team = (eth * TEAM_BPS) / 10_000;
            (bool a,) = platform.call{value: team}("");
            (bool b,) = potVault.call{value: eth - team}("");
            if (!a || !b) revert PayoutFailed();
        }
        uint256 j = jig.balanceOf(address(this));
        if (j > 0) {
            uint256 team = (j * TEAM_BPS) / 10_000;
            jig.safeTransfer(platform, team);
            jig.safeTransfer(potVault, j - team);
        }
    }


    /// @dev PositionManager mints with plain _mint, but accept safe transfers too.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
