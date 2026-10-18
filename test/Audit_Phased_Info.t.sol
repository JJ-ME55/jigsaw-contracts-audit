// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PhasedAuditBase} from "./Audit_Phased_Base.sol";
import {JigsawCollection} from "../src/JigsawCollection.sol";
import {JigsawCollectionFactory} from "../src/JigsawCollectionFactory.sol";

contract Reenter {
    JigsawCollection col;

    constructor(JigsawCollection c) {
        col = c;
    }

    function go() external {
        col.mint{value: 0.0005 ether}(1);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        col.mint{value: 0.0005 ether}(0, 1, new bytes32[](0));
        return this.onERC721Received.selector;
    }
}

contract Audit_Phased_Info is PhasedAuditBase {
    function _ps() internal pure returns (JigsawCollection.Phase[] memory ps) {
        ps = new JigsawCollection.Phase[](1);
        ps[0] = JigsawCollection.Phase({start: T0, price: 0, maxPerWallet: 5, supply: 0, root: bytes32(0)});
    }

    /// Regression (internal round, 18 Oct, I-2): a reserve mint before the first phase no longer locks setPhases.
    function test_reserveMintBeforeStartKeepsSetPhases() public {
        _deploy();
        JigsawCollection col = _create(_cfg(makeAddr("creator"), 1000, 5), _ps(), true, false, "ipfs://p");
        vm.prank(operator);
        col.reserveMint{value: FEE}(1);
        vm.prank(operator);
        col.setPhases(_ps());
        // a public mint still locks them
        vm.warp(T0);
        vm.prank(minter);
        col.mint{value: FEE}(1);
        vm.warp(T0 - 1 hours);
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.PhasesLocked.selector);
        col.setPhases(_ps());
    }

    /// Regression (I-3): freeze with revealLater is refused at creation, and freezing needs a base URI.
    function test_freezeNeedsBaseURI() public {
        _deploy();
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.NothingToFreeze.selector);
        factory.create(_cfg(makeAddr("creator"), 1000, 5), _ps(), keccak256("art"), "ipfs://p", true, true);
        JigsawCollection col = _create(_cfg(makeAddr("creator"), 1000, 5), _ps(), true, false, "ipfs://p");
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.NothingToFreeze.selector);
        col.freezeMetadata();
        vm.prank(operator);
        col.setBaseURI("ipfs://real/");
        vm.prank(operator);
        col.freezeMetadata();
        assertTrue(col.metadataFrozen());
    }

    /// Regression (I-4): the implementation must be a contract.
    function test_eoaImplementationRefused() public {
        _deploy();
        vm.prank(safe);
        vm.expectRevert(JigsawCollectionFactory.NoCode.selector);
        factory.setImplementation(makeAddr("eoa"));
    }

    /// Regression (I-5): ownership cannot be renounced; setPhaseRoot on a missing phase is a named error.
    function test_noRenounce_and_rootIndexChecked() public {
        _deploy();
        JigsawCollection col = _create(_cfg(makeAddr("creator"), 1000, 5), _ps(), true, false, "ipfs://p");
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.CannotRenounce.selector);
        col.renounceOwnership();
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.BadPhases.selector);
        col.setPhaseRoot(3, bytes32(uint256(1)));
    }

    /// Cleared: the implementation cannot be initialized.
    function test_implementationInitializerDisabled() public {
        _deploy();
        JigsawCollection impl = JigsawCollection(factory.implementation());
        vm.expectRevert();
        impl.initialize(_cfg(address(this), 10, 1), address(this), _ps(), keccak256("a"), "x", false, false);
    }

    /// Cleared: re-entry from onERC721Received into the other mint path is blocked.
    function test_reentryFromReceiverBlocked() public {
        _deploy();
        JigsawCollection col = _create(_cfg(makeAddr("creator"), 1000, 5), _ps(), true, false, "ipfs://p");
        Reenter r = new Reenter(col);
        vm.deal(address(r), 1 ether);
        vm.warp(T0);
        vm.expectRevert();
        r.go();
    }

    /// Cleared: setPhases cannot lower caps after any mint, so the subtraction in the cap checks cannot underflow.
    function test_setPhasesAfterMintLocked() public {
        _deploy();
        JigsawCollection.Phase[] memory ps = new JigsawCollection.Phase[](2);
        ps[0] = JigsawCollection.Phase({start: T0, price: 0, maxPerWallet: 5, supply: 3, root: bytes32(0)});
        ps[1] = JigsawCollection.Phase({start: T0 + 1 days, price: 0, maxPerWallet: 5, supply: 0, root: bytes32(0)});
        JigsawCollection col = _create(_cfg(makeAddr("creator"), 1000, 5), ps, true, false, "ipfs://p");
        vm.warp(T0);
        vm.prank(minter);
        col.mint{value: 3 * FEE}(0, 3, new bytes32[](0));
        ps[0].supply = 1;
        ps[0].maxPerWallet = 1;
        vm.prank(operator);
        vm.expectRevert(JigsawCollection.PhasesLocked.selector);
        col.setPhases(ps);
        assertEq(col.mintableNow(0, minter), 0);
    }
}
