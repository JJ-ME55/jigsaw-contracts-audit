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
///         Paid in JIG, which is what the fee hook holds. Accrual is per token id, so
///         whoever owns a token when they claim gets everything accrued to it since the
///         last claim on that token.
contract HolderDrip is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant ACC = 1e18;

    CreatorFeeHook public immutable hook;
    IERC20 public immutable jig;
    IERC721Supply public immutable collection;

    uint256 public accPerToken; // JIG accrued per NFT, scaled by ACC
    uint256 public undistributed; // JIG pulled while supply was 0
    mapping(uint256 tokenId => uint256) public paidPerToken;

    event Pulled(uint256 amount, uint256 supply);
    event Claimed(address indexed to, uint256 tokens, uint256 amount);

    error ZeroAddress();

    constructor(address hook_, address collection_) {
        if (hook_ == address(0) || collection_ == address(0)) revert ZeroAddress();
        hook = CreatorFeeHook(hook_);
        jig = hook.jig();
        collection = IERC721Supply(collection_);
    }

    /// @notice Pull this module's claimable JIG from the hook and spread it over the current supply. Anyone may call.
    function pull() external nonReentrant returns (uint256 amount) {
        amount = hook.claim() + undistributed;
        undistributed = 0;
        uint256 supply = collection.totalSupply();
        if (supply == 0) { undistributed = amount; return amount; }
        accPerToken += (amount * ACC) / supply;
        emit Pulled(amount, supply);
    }

    function owed(uint256 tokenId) public view returns (uint256) {
        return (accPerToken - paidPerToken[tokenId]) / ACC;
    }

    /// @notice Claim for the tokens the caller owns. Reverts if any token is not theirs.
    function claim(uint256[] calldata tokenIds) external nonReentrant returns (uint256 total) {
        for (uint256 i; i < tokenIds.length; i++) {
            uint256 id = tokenIds[i];
            require(collection.ownerOf(id) == msg.sender, "not owner");
            total += owed(id);
            paidPerToken[id] = accPerToken;
        }
        if (total > 0) jig.safeTransfer(msg.sender, total);
        emit Claimed(msg.sender, tokenIds.length, total);
    }
}
