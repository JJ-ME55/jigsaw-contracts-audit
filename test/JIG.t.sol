// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JIG} from "../src/JIG.sol";
import {Vesting} from "../src/Vesting.sol";
import {PotVault} from "../src/PotVault.sol";

contract JIGTest is Test {
    JIG jig;
    Vesting vesting;
    PotVault pot;
    address launch = makeAddr("launch");
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        pot = new PotVault(owner);
        jig = new JIG(launch, address(pot));
        vesting = new Vesting();
    }

    // ---------- JIG ----------

    function test_supply_split() public view {
        assertEq(jig.totalSupply(), 1_000_000_000e18);
        assertEq(jig.balanceOf(launch), 900_000_000e18);
        assertEq(jig.balanceOf(address(pot)), 100_000_000e18);
    }

    function test_no_mint_function() public {
        // JIG exposes no mint; calling a mint selector must revert.
        (bool ok,) = address(jig).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        assertEq(jig.totalSupply(), 1_000_000_000e18);
    }

    function test_burn_reduces_supply() public {
        vm.prank(launch);
        jig.burn(1e18);
        assertEq(jig.totalSupply(), 1_000_000_000e18 - 1e18);
    }

    function test_zero_address_reverts() public {
        vm.expectRevert(JIG.ZeroAddress.selector);
        new JIG(address(0), address(pot));
    }

    // ---------- Vesting ----------

    function _fund(uint256 amount, uint64 cliff, uint64 duration) internal returns (uint256 id) {
        vm.startPrank(launch);
        jig.approve(address(vesting), amount);
        id = vesting.create(address(jig), alice, amount, 0, cliff, duration);
        vm.stopPrank();
    }

    function test_vesting_linear_with_cliff() public {
        uint256 id = _fund(100e18, 30 days, 180 days);
        assertEq(vesting.releasable(id), 0);
        vm.warp(block.timestamp + 29 days);
        assertEq(vesting.releasable(id), 0, "nothing before cliff");
        vm.warp(block.timestamp + 1 days); // day 30
        assertEq(vesting.releasable(id), uint256(100e18) * 30 / 180, "cliff unlocks pro rata");
        vm.warp(block.timestamp + 60 days); // day 90
        assertEq(vesting.releasable(id), 50e18);
        vesting.release(id);
        assertEq(jig.balanceOf(alice), 50e18);
        assertEq(vesting.releasable(id), 0);
        vm.warp(block.timestamp + 365 days);
        assertEq(vesting.releasable(id), 50e18);
        vesting.release(id);
        assertEq(jig.balanceOf(alice), 100e18);
        vm.expectRevert(Vesting.NothingDue.selector);
        vesting.release(id);
    }

    function test_vesting_only_beneficiary_receives() public {
        uint256 id = _fund(100e18, 0, 100 days);
        vm.warp(block.timestamp + 100 days);
        vm.prank(bob); // anyone can trigger, alice still gets it
        vesting.release(id);
        assertEq(jig.balanceOf(alice), 100e18);
        assertEq(jig.balanceOf(bob), 0);
    }

    function test_vesting_bad_inputs() public {
        vm.startPrank(launch);
        jig.approve(address(vesting), 1e18);
        vm.expectRevert(Vesting.BadSchedule.selector);
        vesting.create(address(jig), alice, 1e18, 0, 10, 5); // cliff > duration
        vm.expectRevert(Vesting.ZeroAmount.selector);
        vesting.create(address(jig), alice, 0, 0, 0, 5);
        vm.stopPrank();
    }

    function testFuzz_vesting_never_exceeds_total(uint64 elapsed, uint64 cliff, uint64 duration) public {
        duration = uint64(bound(duration, 1, 10 * 365 days));
        cliff = uint64(bound(cliff, 0, duration));
        uint256 id = _fund(1_000e18, cliff, duration);
        vm.warp(block.timestamp + elapsed);
        assertLe(vesting.vested(id), 1_000e18);
    }

    // ---------- PotVault ----------

    function test_pot_receives_eth_and_tracks_available() public {
        uint256 before = pot.available(address(0));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(pot).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(pot.available(address(0)) - before, 1 ether);
        assertEq(pot.available(address(jig)), 100_000_000e18);
    }

    function test_pot_payouts_off_by_default() public {
        vm.prank(owner);
        vm.expectRevert(PotVault.PayoutsOff.selector);
        pot.declare(address(jig), bytes32(uint256(1)), 1e18, uint64(block.timestamp + 1 days));
    }

    function test_pot_owner_cannot_withdraw() public {
        // There is no withdraw function at all.
        (bool ok,) = address(pot).call(abi.encodeWithSignature("withdraw(address,uint256)", owner, 1));
        assertFalse(ok);
    }

    function test_pot_claim_flow() public {
        // two leaves: alice 60, bob 40
        bytes32 la = keccak256(bytes.concat(keccak256(abi.encode(alice, uint256(60e18)))));
        bytes32 lb = keccak256(bytes.concat(keccak256(abi.encode(bob, uint256(40e18)))));
        bytes32 root = la < lb ? keccak256(abi.encodePacked(la, lb)) : keccak256(abi.encodePacked(lb, la));

        vm.startPrank(owner);
        pot.enablePayouts();
        uint256 id = pot.declare(address(jig), root, 100e18, uint64(block.timestamp + 30 days));
        vm.stopPrank();
        assertEq(pot.available(address(jig)), 100_000_000e18 - 100e18, "reserved while live");

        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = lb;
        pot.claim(id, alice, 60e18, proofA);
        assertEq(jig.balanceOf(alice), 60e18);

        vm.expectRevert(PotVault.AlreadyClaimed.selector);
        pot.claim(id, alice, 60e18, proofA);

        bytes32[] memory bad = new bytes32[](1);
        bad[0] = la;
        vm.expectRevert(PotVault.BadProof.selector);
        pot.claim(id, bob, 41e18, bad);

        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(PotVault.Expired.selector);
        pot.claim(id, bob, 40e18, bad);
        assertEq(pot.available(address(jig)), 100_000_000e18 - 60e18, "unclaimed returns to the pot");
    }

    function test_pot_declare_cannot_exceed_available() public {
        vm.startPrank(owner);
        pot.enablePayouts();
        vm.expectRevert(PotVault.BadDistribution.selector);
        pot.declare(address(jig), bytes32(uint256(1)), 100_000_001e18, uint64(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function test_pot_only_owner_enables() public {
        vm.prank(alice);
        vm.expectRevert();
        pot.enablePayouts();
    }
}
