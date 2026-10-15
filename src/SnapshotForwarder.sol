// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CreatorFeeHook} from "./CreatorFeeHook.sol";
import {HolderPayouts} from "./HolderPayouts.sol";

/// @title SnapshotForwarder
/// @notice Flywheel module for "fees to coin holders" and "split NFT and coin holders":
///         one per coin, its address is the `flywheel` passed to CoinFactory. It pulls the
///         coin's flywheel slice from the hook and delivers it to HolderPayouts under this
///         coin, where the platform's snapshot rounds pay it out. Anyone may call pull().
contract SnapshotForwarder is ReentrancyGuard {
    using SafeERC20 for IERC20;

    CreatorFeeHook public immutable hook;
    IERC20 public immutable jig;
    HolderPayouts public immutable payouts;
    address public immutable coin;

    event Forwarded(uint256 amount);

    error ZeroAddress();

    constructor(address hook_, address payouts_, address coin_) {
        if (hook_ == address(0) || payouts_ == address(0) || coin_ == address(0)) revert ZeroAddress();
        hook = CreatorFeeHook(hook_);
        jig = hook.jig();
        payouts = HolderPayouts(payouts_);
        coin = coin_;
    }

    function pull() external nonReentrant returns (uint256 amount) {
        hook.claim();
        amount = jig.balanceOf(address(this));
        if (amount > 0) {
            jig.forceApprove(address(payouts), amount);
            payouts.fund(coin, amount);
        }
        emit Forwarded(amount);
    }
}
