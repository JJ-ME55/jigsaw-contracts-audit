// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CreatorFeeHook} from "./CreatorFeeHook.sol";

interface IERC721Supply is IERC721 {
    function totalSupply() external view returns (uint256);
}

/// @title HolderDrip
/// @notice Flywheel module (Build Spec §4, "holder drip"): the coin's flywheel slice is
///         paid to the collection's NFT holders pro rata, per token, claimable (pull).
///         One instance per coin; its address is the `flywheel` passed to CoinFactory.
///
///         Paid in JIG, which is what the fee hook holds. Each pull is a checkpoint:
///         {supply at the pull, accumulator before it}. A token only earns from pulls
///         made while it existed. The collection must mint sequential ids from 1 and
///         never decrease totalSupply (LoomCollection does both), so "existed at pull k"
///         is simply id <= supply_k. Tokens sent to the dead address can be marked burned
///         so later pulls split among live tokens only; their past accrual sweeps to the pot.
contract HolderDrip is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant ACC = 1e18;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Checkpoint {
        uint128 supply; // totalSupply at the pull
        uint128 accBefore; // accPerToken before the pull was added
    }

    CreatorFeeHook public immutable hook;
    IERC20 public immutable jig;
    IERC721Supply public immutable collection;
    address public immutable pot;

    uint256 public accPerToken; // JIG accrued per live NFT, scaled by ACC
    uint256 public undistributed; // JIG pulled while live supply was 0
    uint256 public burnedCount;
    Checkpoint[] public checkpoints;
    mapping(uint256 tokenId => uint256) private _paidPerToken;
    mapping(uint256 tokenId => bool) private _seen;
    mapping(uint256 tokenId => bool) public isBurned;

    event Pulled(uint256 amount, uint256 liveSupply);
    event Claimed(address indexed to, uint256 tokens, uint256 amount);
    event MarkedBurned(uint256 indexed tokenId, uint256 strandedToPot);

    error ZeroAddress();
    error NotOwner();
    error NotBurned();

    constructor(address hook_, address collection_) {
        if (hook_ == address(0) || collection_ == address(0)) revert ZeroAddress();
        hook = CreatorFeeHook(hook_);
        jig = hook.jig();
        pot = hook.pot();
        collection = IERC721Supply(collection_);
    }

    /// @notice Pull this module's claimable JIG from the hook and spread it over the live supply. Anyone may call.
    function pull() external nonReentrant returns (uint256 amount) {
        amount = hook.claim() + undistributed;
        undistributed = 0;
        uint256 supply = collection.totalSupply();
        uint256 live = supply - burnedCount;
        if (live == 0 || amount == 0) { undistributed = amount; return amount; }
        checkpoints.push(Checkpoint({supply: uint128(supply), accBefore: uint128(accPerToken)}));
        accPerToken += (amount * ACC) / live;
        emit Pulled(amount, live);
    }

    /// @dev Accumulator value at which `tokenId` started earning: the first checkpoint whose supply covered it.
    function _baseline(uint256 tokenId) internal view returns (uint256) {
        if (_seen[tokenId]) return _paidPerToken[tokenId];
        uint256 n = checkpoints.length;
        uint256 lo;
        uint256 hi = n;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (checkpoints[mid].supply >= tokenId) hi = mid;
            else lo = mid + 1;
        }
        return lo == n ? accPerToken : checkpoints[lo].accBefore;
    }

    function owed(uint256 tokenId) public view returns (uint256) {
        if (isBurned[tokenId]) return 0;
        return (accPerToken - _baseline(tokenId)) / ACC;
    }

    /// @notice Claim for the tokens the caller owns. Reverts if any token is not theirs.
    function claim(uint256[] calldata tokenIds) external nonReentrant returns (uint256 total) {
        for (uint256 i; i < tokenIds.length; i++) {
            uint256 id = tokenIds[i];
            if (collection.ownerOf(id) != msg.sender) revert NotOwner();
            total += owed(id);
            _paidPerToken[id] = accPerToken;
            _seen[id] = true;
        }
        if (total > 0) jig.safeTransfer(msg.sender, total);
        emit Claimed(msg.sender, tokenIds.length, total);
    }

    /// @notice Record that `tokenId` was burned (sent to the dead address). Its unclaimed accrual goes to the pot
    ///         and future pulls split among the remaining live tokens. Anyone may call.
    function markBurned(uint256 tokenId) external nonReentrant {
        if (isBurned[tokenId]) return;
        if (collection.ownerOf(tokenId) != DEAD) revert NotBurned();
        uint256 stranded = (accPerToken - _baseline(tokenId)) / ACC;
        isBurned[tokenId] = true;
        _paidPerToken[tokenId] = accPerToken;
        _seen[tokenId] = true;
        burnedCount++;
        if (stranded > 0) jig.safeTransfer(pot, stranded);
        emit MarkedBurned(tokenId, stranded);
    }

    function checkpointCount() external view returns (uint256) {
        return checkpoints.length;
    }
}
