// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PhasedAuditBase} from "./Audit_Phased_Base.sol";
import {JigsawCollection} from "../src/JigsawCollection.sol";

contract Audit_Phased_LegacyMint is PhasedAuditBase {
    /// Regression (internal round, 18 Oct, I-1): a listed phase may not come after a phase open to anyone, so
    /// mint(quantity) and mintPriceWei always see the public phase once one has started.
    function test_listedPhaseAfterPublicRefused() public {
        _deploy();
        JigsawCollection.Phase[] memory ps = new JigsawCollection.Phase[](2);
        ps[0] = JigsawCollection.Phase({start: T0, price: 0.002 ether, maxPerWallet: 5, supply: 0, root: bytes32(0)});
        ps[1] = JigsawCollection.Phase({start: T0, price: 0.001 ether, maxPerWallet: 5, supply: 0, root: _leaf(address(1))});
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.BadPhases.selector);
        factory.create(_cfg(makeAddr("creator"), 100, 5), ps, keccak256("art"), "ipfs://p", true, false);
        // and setPhaseRoot cannot make one either
        ps[1].root = bytes32(0);
        JigsawCollection col = _create(_cfg(makeAddr("creator"), 100, 5), ps, true, false, "ipfs://p");
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.BadPhases.selector);
        col.setPhaseRoot(1, _leaf(address(1)));
        // nor open phase 0 while phase 1 keeps a list
        JigsawCollection.Phase[] memory qs = new JigsawCollection.Phase[](2);
        qs[0] = JigsawCollection.Phase({start: T0, price: 0, maxPerWallet: 5, supply: 0, root: _leaf(address(1))});
        qs[1] = JigsawCollection.Phase({start: T0 + 1, price: 0, maxPerWallet: 5, supply: 0, root: _leaf(address(2))});
        JigsawCollection c2 = _create(_cfg(makeAddr("creator"), 100, 5), qs, true, false, "ipfs://p");
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.BadPhases.selector);
        c2.setPhaseRoot(0, bytes32(0));
    }

    /// Documented (I-1 case 2): mint(quantity) targets only the latest phase; a sold-out later public phase refuses
    /// it even when an earlier one has room (mint(phase, qty, proof) still reaches the earlier phase).
    function test_legacyMintRoutesToSoldOutPhase() public {
        _deploy();
        JigsawCollection.Phase[] memory ps = new JigsawCollection.Phase[](2);
        ps[0] = JigsawCollection.Phase({start: T0, price: 0, maxPerWallet: 5, supply: 0, root: bytes32(0)});
        ps[1] = JigsawCollection.Phase({start: T0 + 1 hours, price: 0, maxPerWallet: 5, supply: 1, root: bytes32(0)});
        JigsawCollection col = _create(_cfg(makeAddr("creator"), 100, 5), ps, true, false, "ipfs://p");
        vm.warp(T0 + 1 hours);
        vm.prank(minter);
        col.mint{value: FEE}(1);
        vm.prank(minter);
        vm.expectRevert(JigsawCollection.PhaseSupplyExceeded.selector);
        col.mint{value: FEE}(1);
    }
}
