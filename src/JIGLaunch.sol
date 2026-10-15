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

/// @title JIGLaunch
/// @notice One-shot fair launch of the JIG/ETH Uniswap v4 pool (spec 2).
///         Holds 90% of JIG supply from birth. `launch` creates the pool, seeds it
///         single-sided with every JIG it holds, and mints the LP position to this
///         contract. There is no function to transfer the position or remove
///         liquidity, so the LP is locked forever. LP fees can be collected by
///         anyone, and only ever go to the pot vault.
///
///         Single-sided: the range sits entirely below the starting price
///         (tickLower < tickUpper <= startTick), so the position holds JIG only.
///         As buyers pay ETH for JIG the price moves down into the range and the
///         position accrues ETH.
contract JIGLaunch {
    using SafeERC20 for IERC20;

    IPositionManager public immutable posm;
    IAllowanceTransfer public immutable permit2;
    address public immutable launcher;
    address public immutable potVault;

    IERC20 public jig;
    PoolKey public poolKey;
    uint256 public tokenId;
    bool public launched;

    event Launched(uint256 indexed tokenId, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 jigSeeded);
    event FeesCollected(address indexed to);

    error NotLauncher();
    error AlreadyLaunched();
    error NotLaunched();
    error JigNotSet();
    error RangeNotBelowPrice();
    error ZeroAddress();

    constructor(address posm_, address permit2_, address launcher_, address potVault_) {
        if (posm_ == address(0) || permit2_ == address(0) || launcher_ == address(0) || potVault_ == address(0)) revert ZeroAddress();
        posm = IPositionManager(posm_);
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
        posm.initializePool(poolKey, sqrtPriceX96);

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

    /// @notice Collect accrued LP fees to the pot vault. Anyone may call. Liquidity is untouched.
    function collectFees() external {
        if (!launched) revert NotLaunched();
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, potVault);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        emit FeesCollected(potVault);
    }

    /// @dev PositionManager mints with plain _mint, but accept safe transfers too.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
