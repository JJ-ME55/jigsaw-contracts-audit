// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JigsawCollection} from "../src/JigsawCollection.sol";
import {JigsawCollectionFactory} from "../src/JigsawCollectionFactory.sol";

/// VIP 10:00, WL 13:00, public 17:00 (Jj, 17 Oct). Fixed absolute times: under via_ir a saved block.timestamp can be
/// re-read after vm.warp.
contract JigsawCollectionTest is Test {
    uint64 constant VIP = 1_800_000_000;
    uint64 constant WL = VIP + 3 hours;
    uint64 constant PUB = VIP + 7 hours;
    uint256 constant FEE = 0.0005 ether;

    address platform = makeAddr("platform");
    address operator = makeAddr("operator");
    address safe = makeAddr("safe");
    address creator = makeAddr("creator");
    address vip = makeAddr("vip");
    address wl = makeAddr("wl");
    address other = makeAddr("other");

    JigsawCollectionFactory factory;
    JigsawCollection col;
    bytes32 vipRoot;
    bytes32 wlRoot;

    function _leaf(address a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// two-leaf trees: VIP {vip, other}, WL {wl, vip}; the proof is the sibling leaf
    function _proof(address a, uint256 phase) internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        if (phase == 0) p[0] = _leaf(a == vip ? other : vip);
        else p[0] = _leaf(a == wl ? vip : wl);
    }

    function _phases() internal view returns (JigsawCollection.Phase[] memory ps) {
        ps = new JigsawCollection.Phase[](3);
        ps[0] = JigsawCollection.Phase({start: VIP, price: 0, maxPerWallet: 2, supply: 50, root: vipRoot});
        ps[1] = JigsawCollection.Phase({start: WL, price: 0.001 ether, maxPerWallet: 3, supply: 0, root: wlRoot});
        ps[2] = JigsawCollection.Phase({start: PUB, price: 0.002 ether, maxPerWallet: 5, supply: 0, root: bytes32(0)});
    }

    function _config() internal view returns (JigsawCollection.Config memory) {
        return JigsawCollection.Config({name: "Cool", symbol: "COOL", maxSupply: 100, maxPerWallet: 6, creator: creator, royaltyBps: 500});
    }

    function setUp() public {
        vm.warp(VIP - 1 days);
        vipRoot = _pair(_leaf(vip), _leaf(other));
        wlRoot = _pair(_leaf(wl), _leaf(vip));
        JigsawCollection impl = new JigsawCollection(platform, platform);
        factory = new JigsawCollectionFactory(address(impl), operator, safe);
        vm.prank(operator);
        col = JigsawCollection(factory.create(_config(), _phases(), keccak256("art"), "ipfs://placeholder", true, false));
        vm.deal(vip, 1 ether);
        vm.deal(wl, 1 ether);
        vm.deal(other, 1 ether);
    }

    function _mint(address who, uint256 phase, uint256 qty, uint256 price, bytes32[] memory proof) internal {
        vm.prank(who);
        col.mint{value: (price + FEE) * qty}(phase, qty, proof);
    }

    function test_createdConfiguredAndRegistered() public view {
        assertTrue(factory.isCollection(address(col)));
        assertEq(col.owner(), operator);
        assertEq(col.provenanceHash(), keccak256("art"));
        assertEq(col.phaseCount(), 3);
        assertEq(col.currentPhase(), type(uint256).max);
    }

    function test_nothingBeforeVip() public {
        vm.expectRevert(abi.encodeWithSelector(JigsawCollection.PhaseNotOpen.selector, 0));
        _mint(vip, 0, 1, 0, _proof(vip, 0));
        vm.expectRevert(abi.encodeWithSelector(JigsawCollection.PhaseNotOpen.selector, 0));
        vm.prank(other);
        col.mint{value: FEE}(1);
    }

    function test_vipWindow_listOnly_andPhaseCap() public {
        vm.warp(VIP);
        _mint(vip, 0, 2, 0, _proof(vip, 0));
        assertEq(col.balanceOf(vip), 2);
        vm.expectRevert(JigsawCollection.PhaseCapExceeded.selector);
        _mint(vip, 0, 1, 0, _proof(vip, 0));
        // wl is not on the VIP list
        vm.expectRevert(JigsawCollection.NotOnList.selector);
        _mint(wl, 0, 1, 0, _proof(wl, 0));
        // WL phase not open yet
        vm.expectRevert(abi.encodeWithSelector(JigsawCollection.PhaseNotOpen.selector, 1));
        _mint(wl, 1, 1, 0.001 ether, _proof(wl, 1));
        // a listed phase cannot be minted through mint(quantity)
        vm.expectRevert(JigsawCollection.UsePhaseMint.selector);
        vm.prank(other);
        col.mint{value: FEE}(1);
    }

    function test_wlWindow_priceAndVipCarriesOver() public {
        vm.warp(WL);
        _mint(wl, 1, 3, 0.001 ether, _proof(wl, 1));
        vm.expectRevert(JigsawCollection.PhaseCapExceeded.selector);
        _mint(wl, 1, 1, 0.001 ether, _proof(wl, 1));
        // wrong price
        vm.prank(vip);
        vm.expectRevert(abi.encodeWithSelector(JigsawCollection.IncorrectPayment.selector, 2 * (0.001 ether + FEE), 2 * FEE));
        col.mint{value: 2 * FEE}(1, 2, _proof(vip, 1));
        // VIP phase stays open for VIPs who haven't used it
        _mint(vip, 0, 1, 0, _proof(vip, 0));
        assertEq(col.creator().balance, 3 * (0.001 ether + FEE * 40 / 100) + FEE * 40 / 100);
    }

    function test_publicWindow_lifetimeCapAcrossPhases() public {
        vm.warp(PUB);
        _mint(vip, 0, 2, 0, _proof(vip, 0));
        _mint(vip, 1, 3, 0.001 ether, _proof(vip, 1));
        // lifetime cap 6: only one left even though public allows 5
        vm.expectRevert(JigsawCollection.WalletCapExceeded.selector);
        _mint(vip, 2, 2, 0.002 ether, new bytes32[](0));
        assertEq(col.mintableNow(2, vip), 1);
        _mint(vip, 2, 1, 0.002 ether, new bytes32[](0));
        // anyone through the Loom-style mint
        vm.prank(other);
        col.mint{value: 0.002 ether + FEE}(1);
        assertEq(col.balanceOf(other), 1);
        assertEq(col.mintPriceWei(), 0.002 ether);
    }

    function test_phaseSupplyCap() public {
        JigsawCollection.Phase[] memory ps = _phases();
        ps[0].supply = 3;
        vm.prank(operator);
        col.setPhases(ps);
        vm.warp(VIP);
        _mint(vip, 0, 2, 0, _proof(vip, 0));
        vm.expectRevert(JigsawCollection.PhaseSupplyExceeded.selector);
        _mint(other, 0, 2, 0, _proof(other, 0));
        _mint(other, 0, 1, 0, _proof(other, 0));
    }

    function test_setPhasesLockedOnceStarted_rootUntilPhaseStarts() public {
        vm.warp(VIP);
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.PhasesLocked.selector);
        col.setPhases(_phases());
        // WL list can still change until 13:00
        vm.prank(operator);
        col.setPhaseRoot(1, _leaf(other));
        vm.warp(WL);
        _mint(other, 1, 1, 0.001 ether, new bytes32[](0));
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.PhasesLocked.selector);
        col.setPhaseRoot(1, bytes32(0));
    }

    function test_badPhasesRejected() public {
        JigsawCollection.Phase[] memory ps = _phases();
        ps[1].start = VIP - 1; // out of order
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.BadPhases.selector);
        col.setPhases(ps);
        ps = _phases();
        ps[2].maxPerWallet = 7; // above the lifetime cap
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.BadPhases.selector);
        col.setPhases(ps);
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.BadPhases.selector);
        col.setPhases(new JigsawCollection.Phase[](0));
    }

    function test_onlyOperatorCreates_onlyOwnerSetsPhases() public {
        vm.prank(other);
        vm.expectRevert(JigsawCollectionFactory.NotOperator.selector);
        factory.create(_config(), _phases(), keccak256("art"), "x", true, false);
        vm.prank(other);
        vm.expectRevert();
        col.setPhases(_phases());
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.BadProvenance.selector);
        factory.create(_config(), _phases(), bytes32(0), "x", true, false);
    }

    function test_immediateRevealFreezes() public {
        vm.prank(operator);
        JigsawCollection c2 = JigsawCollection(factory.create(_config(), _phases(), keccak256("art"), "ipfs://base/", false, true));
        assertTrue(c2.metadataFrozen());
        assertEq(c2.baseURI(), "ipfs://base/");
    }

    function test_pauseStopsAllPhases() public {
        vm.warp(PUB);
        vm.prank(operator);
        col.pause();
        vm.expectRevert();
        _mint(other, 2, 1, 0.002 ether, new bytes32[](0));
        assertEq(col.mintableNow(2, other), 0);
    }
}
