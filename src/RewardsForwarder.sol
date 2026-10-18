// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CreatorFeeHook} from "./CreatorFeeHook.sol";
import {CoinFactory} from "./CoinFactory.sol";
import {CreatorCoin} from "./CreatorCoin.sol";

/// @title RewardsForwarder
/// @notice Flywheel module for "fees to coin holders": one per collection, its address is the `flywheel` passed to
///         CoinFactory (which makes it the coin's reward notifier). pull() claims the coin's flywheel slice from the
///         hook and hands it to the coin, which streams it to holders on chain (CreatorCoin). No key and no
///         snapshot: anyone may call pull() (once a day), and because rewards stream over one day (CreatorCoin.DURATION), choosing when
///         to pull gains nobody anything. Replaces SnapshotForwarder + HolderPayouts (Jj, 17 Oct).
contract RewardsForwarder is ReentrancyGuard {
    using SafeERC20 for IERC20;

    CreatorFeeHook public immutable hook;
    IERC20 public immutable jig;
    CoinFactory public immutable factory;
    address public immutable collection;
    uint64 public constant MIN_INTERVAL = 1 days; // == CreatorCoin.DURATION: the previous stream has ended when the next pull is allowed
    uint64 public lastPull;

    event Forwarded(uint256 amount);

    error ZeroAddress();
    error NoCoinYet();
    error TooSoon();

    constructor(address hook_, address factory_, address collection_) {
        if (hook_ == address(0) || factory_ == address(0) || collection_ == address(0)) revert ZeroAddress();
        hook = CreatorFeeHook(hook_);
        jig = hook.jig();
        factory = CoinFactory(factory_);
        collection = collection_;
    }

    /// @notice The coin this module feeds, read from the factory.
    function rewardsCoin() public view returns (CreatorCoin c) {
        address a = factory.coinOf(collection);
        if (a == address(0)) revert NoCoinYet();
        c = CreatorCoin(a);
    }

    /// @notice When pull() can next run.
    function nextPullAt() external view returns (uint256) {
        return lastPull == 0 ? 0 : uint256(lastPull) + MIN_INTERVAL;
    }

    /// @notice Anyone may call, at most once a day. The coin streams each pull over CreatorCoin.DURATION (1 day) and
    ///         MIN_INTERVAL equals it, so the previous stream has always ended when the next pull is allowed: nothing is
    ///         ever re-spread or stretched (review 17 Oct; round 8, Info 8). With no new JIG, a pull still re-streams the
    ///         coin's carry (reward streamed while nobody was eligible) so it reaches later holders (round 8, Info 10).
    function pull() external nonReentrant returns (uint256 amount) {
        if (lastPull != 0 && block.timestamp < uint256(lastPull) + MIN_INTERVAL) revert TooSoon();
        lastPull = uint64(block.timestamp);
        hook.claim();
        amount = jig.balanceOf(address(this));
        if (amount > 0) {
            CreatorCoin c = rewardsCoin();
            jig.forceApprove(address(c), amount);
            c.notifyReward(amount);
        } else {
            address a = factory.coinOf(collection);
            if (a != address(0) && CreatorCoin(a).carry() > 0 && !CreatorCoin(a).rewardsPaused()) CreatorCoin(a).notifyReward(0);
        }
        emit Forwarded(amount);
    }
}
