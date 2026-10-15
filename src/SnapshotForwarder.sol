// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CreatorFeeHook} from "./CreatorFeeHook.sol";
import {HolderPayouts} from "./HolderPayouts.sol";
import {CoinFactory} from "./CoinFactory.sol";

/// @title SnapshotForwarder
/// @notice Flywheel module for "fees to coin holders" and "split NFT and coin holders":
///         one per collection, its address is the `flywheel` passed to CoinFactory. It pulls
///         the coin's flywheel slice from the hook and delivers it to HolderPayouts under the
///         collection's coin (resolved from the factory), where the platform's snapshot rounds
///         pay it out. Anyone may call pull().
contract SnapshotForwarder is ReentrancyGuard {
    using SafeERC20 for IERC20;

    CreatorFeeHook public immutable hook;
    IERC20 public immutable jig;
    HolderPayouts public immutable payouts;
    CoinFactory public immutable factory;
    address public immutable collection;

    event Forwarded(uint256 amount);

    error ZeroAddress();
    error NoCoinYet();

    constructor(address hook_, address payouts_, address factory_, address collection_) {
        if (hook_ == address(0) || payouts_ == address(0) || factory_ == address(0) || collection_ == address(0)) revert ZeroAddress();
        hook = CreatorFeeHook(hook_);
        jig = hook.jig();
        payouts = HolderPayouts(payouts_);
        factory = CoinFactory(factory_);
        collection = collection_;
    }

    /// @notice The coin this forwarder serves, read from the factory so deploy order cannot bind it to the wrong coin.
    function coin() public view returns (address c) {
        c = factory.coinOf(collection);
        if (c == address(0)) revert NoCoinYet();
    }

    function pull() external nonReentrant returns (uint256 amount) {
        hook.claim();
        amount = jig.balanceOf(address(this));
        if (amount > 0) {
            jig.forceApprove(address(payouts), amount);
            payouts.fund(coin(), amount);
        }
        emit Forwarded(amount);
    }
}
