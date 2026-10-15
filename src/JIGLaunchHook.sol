// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title JIGLaunchHook
/// @notice The launch-window hook for the JIG/ETH pool (launch plan, 15 Oct 2026).
///
///   - For WINDOW (10 minutes) after the pool is initialised, a swap whose tx.origin
///     is on the allowlist pays NORMAL_FEE (1%); every other swap pays OUTSIDER_FEE
///     (60%). After the window everyone pays 1%. All of it is LP fee, and the only LP
///     is JIGLaunch, whose fees go to the pot. So the sniper tax fills the pot.
///   - The allowlist is a merkle root of keccak256(abi.encode(address)) leaves
///     (OpenZeppelin double-hash), set by the owner before the pool exists. Swappers
///     pass their proof as hookData. tx.origin is used on purpose: a router can lie
///     about msg.sender but nobody can fake the EOA that signed the transaction.
///   - Serves exactly one pool: ETH / JIG with the dynamic-fee flag. Any other pool
///     that points at this hook is refused at initialisation.
///
/// Address must carry exactly BEFORE_INITIALIZE_FLAG | BEFORE_SWAP_FLAG (0x2080) in
/// its low 14 bits; the deploy script mines a CREATE2 salt for that.
contract JIGLaunchHook is IHooks {
    using LPFeeLibrary for uint24;

    uint24 public constant NORMAL_FEE = 10_000; // 1%
    uint24 public constant OUTSIDER_FEE = 600_000; // 60%
    uint64 public constant WINDOW = 10 minutes;

    IPoolManager public immutable poolManager;
    address public immutable jig;
    address public immutable owner;

    bytes32 public allowlistRoot;
    uint64 public windowEnd; // 0 until the pool is initialised
    bool public initialized;

    event AllowlistSet(bytes32 root);
    event WindowOpened(uint64 windowEnd);

    error NotPoolManager();
    error NotOwner();
    error AlreadyInitialized();
    error WrongPool();
    error HookNotImplemented();

    constructor(address poolManager_, address jig_, address owner_) {
        poolManager = IPoolManager(poolManager_);
        jig = jig_;
        owner = owner_;
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
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Set or replace the allowlist. Only before the pool exists.
    function setAllowlist(bytes32 root) external {
        if (msg.sender != owner) revert NotOwner();
        if (initialized) revert AlreadyInitialized();
        allowlistRoot = root;
        emit AllowlistSet(root);
    }

    /// @notice True if `account` can prove it is on the allowlist.
    function isAllowlisted(address account, bytes32[] calldata proof) public view returns (bool) {
        if (allowlistRoot == bytes32(0)) return false;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account))));
        return MerkleProof.verify(proof, allowlistRoot, leaf);
    }

    /// @notice The fee a swap by `account` would pay right now.
    function quoteFee(address account, bytes32[] calldata proof) external view returns (uint24) {
        if (block.timestamp >= windowEnd) return NORMAL_FEE;
        return isAllowlisted(account, proof) ? NORMAL_FEE : OUTSIDER_FEE;
    }

    // ---------------- hooks ----------------

    function beforeInitialize(address, PoolKey calldata key, uint160) external override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (initialized) revert AlreadyInitialized();
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != jig
                || !key.fee.isDynamicFee()
        ) revert WrongPool();
        initialized = true;
        windowEnd = uint64(block.timestamp) + WINDOW;
        emit WindowOpened(windowEnd);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
        external
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint24 fee = NORMAL_FEE;
        if (block.timestamp < windowEnd) {
            fee = OUTSIDER_FEE;
            if (hookData.length >= 32) {
                bytes32[] memory proof = abi.decode(hookData, (bytes32[]));
                bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(tx.origin))));
                if (allowlistRoot != bytes32(0) && MerkleProof.verify(proof, allowlistRoot, leaf)) fee = NORMAL_FEE;
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ---------------- unused hooks ----------------

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
