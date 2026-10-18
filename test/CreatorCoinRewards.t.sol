// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CreatorCoin} from "../src/CreatorCoin.sol";

contract RJig is ERC20 {
    constructor() ERC20("J", "J") {}
    function mint(address a, uint256 v) external { _mint(a, v); }
}

/// Stands in for CoinFactory: deploys the coin (so it is the coin's factory) and answers platform().
contract CoinMaker {
    address public platform;
    constructor(address platform_) { platform = platform_; }
    function make(address jig, address[] memory ex) external returns (CreatorCoin c) {
        c = new CreatorCoin("Coin", "C", 1_000_000_000e18, address(0xC011), address(this), jig, ex);
    }
    function setNotifier(CreatorCoin c, address n) external { c.setNotifier(n); }
    function give(CreatorCoin c, address to, uint256 v) external { c.transfer(to, v); }
}

/// Holder rewards on chain (Jj, 17 Oct): JIG streams to holders pro rata to balance x time, protocol addresses
/// excluded, no key decides anything; the platform can only pause adding and claiming.
contract CreatorCoinRewardsTest is Test {
    RJig jig; CoinMaker maker; CreatorCoin coin;
    address platform = makeAddr("platform");
    address pool = makeAddr("poolManager");
    address notifier = makeAddr("forwarder");
    address alice = makeAddr("alice"); address bob = makeAddr("bob"); address eve = makeAddr("eve");
    uint256 constant D = 1 days; // the stream (18 Oct: what comes in one day pays out over the next 24 h)

    function setUp() public {
        jig = new RJig();
        maker = new CoinMaker(platform);
        address[] memory ex = new address[](1); ex[0] = pool;
        coin = maker.make(address(jig), ex);
        maker.setNotifier(coin, notifier);
        maker.give(coin, pool, 900_000_000e18); // the pool's coins are excluded
        jig.mint(notifier, 1_000_000e18);
        vm.prank(notifier); jig.approve(address(coin), type(uint256).max);
    }

    function _notify(uint256 a) internal { vm.prank(notifier); coin.notifyReward(a); }

    function test_rewards_stream_pro_rata_to_holders_and_skip_excluded() public {
        maker.give(coin, alice, 30e18); maker.give(coin, bob, 10e18);
        assertEq(coin.eligibleSupply(), 40e18, "only alice and bob are eligible");
        _notify(700e18);
        vm.warp(block.timestamp + D);
        assertApproxEqRel(coin.earned(alice), 525e18, 1e12, "3/4 of the stream");
        assertApproxEqRel(coin.earned(bob), 175e18, 1e12, "1/4 of the stream");
        assertEq(coin.earned(pool), 0, "excluded");
        vm.prank(alice); uint256 got = coin.claim();
        assertEq(jig.balanceOf(alice), got);
        assertLe(coin.earned(alice) + coin.earned(bob) + got, 700e18, "never more than streamed");
    }

    function test_buying_just_before_a_reward_earns_only_the_time_held() public {
        maker.give(coin, alice, 10e18);
        _notify(700e18);
        vm.warp(block.timestamp + D - 1 hours);
        maker.give(coin, eve, 1_000e18); // eve buys 100x alice's stake an hour before the end
        vm.warp(block.timestamp + 1 hours);
        // alice earned ~23/24 of the day alone plus a sliver of the last hour; eve at most the last hour's 700/24
        assertTrue(coin.earned(eve) <= uint256(700e18) / 24, "an hour of rewards at most");
        assertTrue(coin.earned(alice) > uint256(690e18) * 23 / 24, "alice keeps what accrued before");
    }

    function test_transfers_carry_no_past_rewards() public {
        maker.give(coin, alice, 10e18);
        _notify(70e18);
        vm.warp(block.timestamp + D / 2);
        uint256 a = coin.earned(alice);
        vm.prank(alice); coin.transfer(bob, 10e18);
        assertEq(coin.earned(alice), a, "alice keeps what she earned");
        assertEq(coin.earned(bob), 0, "bob gets nothing from before he held");
        vm.warp(block.timestamp + D / 2);
        assertApproxEqRel(coin.earned(bob), 35e18, 1e12, "bob earns from now");
    }

    function test_reward_while_nobody_is_eligible_is_kept_for_the_next_stream() public {
        uint256 t0 = block.timestamp; // explicit times: under via_ir block.timestamp can read stale after vm.warp
        _notify(70e18); // no eligible holder yet
        vm.warp(t0 + D);
        maker.give(coin, alice, 1e18);
        assertEq(coin.earned(alice), 0);
        _notify(0); // the next notify restreams what nobody could earn
        vm.warp(t0 + 2 * D);
        assertApproxEqRel(coin.earned(alice), 70e18, 1e12, "nothing lost");
    }

    function test_burns_shrink_the_eligible_supply() public {
        maker.give(coin, alice, 10e18); maker.give(coin, bob, 10e18);
        vm.prank(bob); coin.burn(10e18);
        assertEq(coin.eligibleSupply(), 10e18);
        _notify(70e18);
        vm.warp(block.timestamp + D);
        assertApproxEqRel(coin.earned(alice), 70e18, 1e12, "alice is the only holder left");
    }

    function test_only_the_notifier_adds_rewards_and_it_is_set_once() public {
        vm.expectRevert(CreatorCoin.NotNotifier.selector);
        vm.prank(eve); coin.notifyReward(1);
        vm.expectRevert(CreatorCoin.NotFactory.selector);
        vm.prank(eve); coin.setNotifier(eve);
        vm.expectRevert(CreatorCoin.NotifierSet_.selector);
        maker.setNotifier(coin, eve);
    }

    function test_the_platform_can_pause_adding_and_claiming_but_cannot_take_anything() public {
        maker.give(coin, alice, 10e18);
        _notify(70e18);
        vm.prank(eve); vm.expectRevert(CreatorCoin.NotPlatform.selector); coin.setRewardsPaused(true);
        vm.prank(platform); coin.setRewardsPaused(true);
        vm.warp(block.timestamp + D);
        vm.prank(alice); vm.expectRevert(CreatorCoin.Paused.selector); coin.claim();
        vm.prank(notifier); vm.expectRevert(CreatorCoin.Paused.selector); coin.notifyReward(1);
        vm.prank(alice); coin.transfer(bob, 1e18); // trading carries on
        uint256 owed = coin.earned(alice);
        assertTrue(owed > 0, "accrual carries on while paused");
        vm.prank(platform); coin.setRewardsPaused(false);
        vm.prank(alice); assertEq(coin.claim(), owed, "resumes exactly where it was");
        assertEq(jig.balanceOf(platform), 0, "the platform never receives anything");
    }

    // review, 17 Oct: an emergency pause cannot freeze holders' rewards indefinitely: it lapses after MAX_PAUSE unless
    // the platform renews it, and renewing is a deliberate act each time
    function test_a_pause_expires_by_itself_unless_renewed() public {
        uint256 t0 = 1_000_000; // fixed times: under via_ir a saved block.timestamp can be re-read after vm.warp
        vm.warp(t0);
        maker.give(coin, alice, 10e18);
        _notify(70e18);
        vm.prank(platform); coin.setRewardsPaused(true);
        assertTrue(coin.rewardsPaused());
        assertEq(coin.MAX_PAUSE(), 14 days);
        vm.warp(t0 + 14 days - 1);
        vm.prank(alice); vm.expectRevert(CreatorCoin.Paused.selector); coin.claim();
        vm.prank(platform); coin.setRewardsPaused(true); // renewed: another MAX_PAUSE from now
        vm.warp(t0 + 28 days - 2);
        assertTrue(coin.rewardsPaused(), "still paused after a renewal");
        vm.warp(t0 + 28 days);
        assertTrue(!coin.rewardsPaused(), "lapsed by itself");
        vm.prank(alice); assertTrue(coin.claim() > 0, "claims work again without anyone unpausing");
    }

    function test_a_top_up_mid_stream_adds_to_what_is_left() public {
        maker.give(coin, alice, 10e18);
        _notify(70e18);
        vm.warp(block.timestamp + D / 2);
        _notify(70e18); // 35 left + 70 new, over a fresh day
        vm.warp(block.timestamp + D);
        assertApproxEqRel(coin.earned(alice), 140e18, 1e12, "everything streamed, nothing lost");
    }

    /// Regression (Jj, 18 Oct): "can't we just give out what comes in?" One day's rewards pay out in full over the
    /// next 24 hours, so when the forwarder's next pull is allowed (once a day) nothing is left to re-spread: no
    /// reward is ever stretched past the day after it arrived.
    function test_each_days_rewards_pay_out_in_full_within_a_day() public {
        assertEq(coin.DURATION(), 1 days);
        uint256 t0 = 1_800_000_000; // absolute times: under via_ir a saved block.timestamp is re-read after vm.warp
        vm.warp(t0);
        maker.give(coin, alice, 10e18);
        _notify(240e18);
        vm.warp(t0 + 1 days); // the next pull is allowed now
        assertApproxEqRel(coin.earned(alice), 240e18, 1e12, "the whole day's intake paid");
        _notify(48e18);
        assertApproxEqAbs(coin.rewardRate(), uint256(48e18) / 1 days, 1, "the new day streams only what came in today");
        vm.warp(t0 + 2 days);
        assertApproxEqRel(coin.earned(alice), 288e18, 1e12, "and that too, by the end of the next day");
    }
}
