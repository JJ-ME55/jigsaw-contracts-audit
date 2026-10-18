// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {JigsawCollection} from "../src/JigsawCollection.sol";
import {JigsawCollectionFactory} from "../src/JigsawCollectionFactory.sol";
import {CollectionLauncher} from "../src/CollectionLauncher.sol";
import {CreatorCoin} from "../src/CreatorCoin.sol";
import {RewardsForwarder} from "../src/RewardsForwarder.sol";

/// Swarm audit round 8 (job 70fa509e, 18 Oct): regressions for Low 3, Low 5, Info 7 and Info 10.
contract A8Jig is ERC20 {
    constructor() ERC20("J", "J") {}
    function mint(address a, uint256 v) external { _mint(a, v); }
}

/// Stands in for CreatorFeeHook (jig(), claim() with nothing owed) and CoinFactory (coinOf, platform).
contract A8HookFactory {
    address public jig; address public coin; address public platform;
    constructor(address jig_) { jig = jig_; platform = msg.sender; }
    function claim() external pure returns (uint256) { return 0; }
    function setCoin(address c) external { coin = c; }
    function coinOf(address) external view returns (address) { return coin; }
}

contract Audit8RestTest is Test {
    uint64 constant T0 = 1_800_000_000;
    address operator = makeAddr("operator");
    address safe = makeAddr("safe");
    address creator = makeAddr("creator");

    function _phases() internal pure returns (JigsawCollection.Phase[] memory ps) {
        ps = new JigsawCollection.Phase[](1);
        ps[0] = JigsawCollection.Phase({start: T0, price: 0, maxPerWallet: 5, supply: 0, root: bytes32(0)});
    }

    function _cfg() internal view returns (JigsawCollection.Config memory) {
        return JigsawCollection.Config({name: "N", symbol: "S", maxSupply: 100, maxPerWallet: 10, creator: creator, royaltyBps: 500});
    }

    function _factory() internal returns (JigsawCollectionFactory f) {
        vm.warp(T0 - 1 days);
        f = new JigsawCollectionFactory(address(new JigsawCollection(safe, safe)), operator, safe);
    }

    /// Low 3: freezing at creation needs a base URI, as freezeMetadata() does.
    function test_low3_freeze_at_creation_needs_a_base_uri() public {
        JigsawCollectionFactory f = _factory();
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.NothingToFreeze.selector);
        f.create(_cfg(), _phases(), bytes32(uint256(1)), "", false, true);
        vm.prank(operator);
        JigsawCollection c = JigsawCollection(f.create(_cfg(), _phases(), bytes32(uint256(1)), "ipfs://base/", false, true));
        assertTrue(c.metadataFrozen());
    }

    /// Low 5: the factory's owner (the Safe) can hand a clone to a new owner if the operator key is lost or leaked.
    function test_low5_safe_recovers_a_clone_from_a_lost_operator() public {
        JigsawCollectionFactory f = _factory();
        vm.prank(operator);
        JigsawCollection c = JigsawCollection(f.create(_cfg(), _phases(), bytes32(uint256(1)), "ipfs://p", true, false));
        address newOps = makeAddr("newOps");
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.NotFactoryOwner.selector);
        c.recoverOwnership(operator); // the operator itself cannot use the hatch
        vm.prank(safe);
        c.recoverOwnership(newOps);
        assertEq(c.owner(), newOps);
        vm.prank(newOps);
        c.pause(); // the new owner administers it
        vm.prank(safe);
        vm.expectRevert(JigsawCollection.ZeroAddress.selector);
        c.recoverOwnership(address(0));
    }

    /// Info 7: CollectionLauncher refuses freeze with revealLater, as JigsawCollection does.
    function test_info7_launcher_refuses_freeze_with_reveal_later() public {
        CollectionLauncher l = new CollectionLauncher(makeAddr("loomFactory"), operator, safe);
        CollectionLauncher.Collection memory c = CollectionLauncher.Collection({name: "N", symbol: "S", maxSupply: 10, mintPriceWei: 0, maxPerWallet: 1, creator: creator, royaltyBps: 0});
        vm.prank(operator);
        vm.expectRevert(CollectionLauncher.NothingToFreeze.selector);
        l.create(c, bytes32(uint256(1)), "ipfs://placeholder", true, true);
    }

    /// Info 10: reward streamed while nobody was eligible (carry) is re-streamed by the next pull even when no new
    /// fees came in, so it reaches holders who arrive later.
    function test_info10_carry_reaches_later_holders_without_new_fees() public {
        vm.warp(T0);
        A8Jig jig = new A8Jig();
        A8HookFactory hf = new A8HookFactory(address(jig));
        RewardsForwarder fwd = new RewardsForwarder(address(hf), address(hf), makeAddr("collection"));
        address[] memory ex = new address[](0);
        CreatorCoin coin = new CreatorCoin("C", "C", 1_000e18, makeAddr("collection"), address(this), address(jig), ex);
        coin.setNotifier(address(fwd));
        hf.setCoin(address(coin));
        // the coin's whole supply sits with this contract (the factory stand-in, excluded): nobody is eligible
        jig.mint(address(fwd), 70e18);
        fwd.pull(); // streams 70 JIG to nobody
        vm.warp(T0 + 1 days);
        coin.transfer(makeAddr("alice"), 10e18); // alice arrives; then trading stops: nothing new to pull
        vm.warp(T0 + 1 days + 1);
        assertGt(coin.carry(), 69e18, "the day's stream became carry");
        fwd.pull(); // amount 0, but the carry is re-streamed
        vm.warp(T0 + 2 days + 2);
        assertApproxEqRel(coin.earned(makeAddr("alice")), 70e18, 1e15, "alice receives the carried reward");
    }

    // platform() for CreatorCoin's pause check (this contract is the coin's factory)
    function platform() external view returns (address) { return safe; }
}

/// Swarm audit round 9, Info 6: a pull with no new JIG re-streams the carry only when it can pay at least 1 wei a
/// second; division dust (< DURATION wei) stays as carry and the running stream's schedule is left alone.
contract Audit9DustTest is Test {
    function platform() external pure returns (address) { return address(0xBEEF); }

    function test_info6_dust_carry_does_not_restart_the_stream() public {
        vm.warp(1_800_000_000);
        A8Jig jig = new A8Jig();
        A8HookFactory hf = new A8HookFactory(address(jig));
        RewardsForwarder fwd = new RewardsForwarder(address(hf), address(hf), makeAddr("collection"));
        CreatorCoin coin = new CreatorCoin("C", "C", 1_000e18, makeAddr("collection"), address(this), address(jig), new address[](0));
        coin.setNotifier(address(fwd));
        hf.setCoin(address(coin));
        coin.transfer(makeAddr("alice"), 100e18);
        jig.mint(address(fwd), 1_000e18 + 12_345);
        fwd.pull();
        assertGt(coin.carry(), 0, "division dust");
        assertLt(coin.carry(), 1 days, "only dust");
        uint256 finish = coin.periodFinish();
        vm.warp(1_800_000_000 + 1 days);
        fwd.pull(); // no new JIG, only dust: nothing to re-stream
        assertEq(coin.periodFinish(), finish, "stream schedule untouched");
    }
}
