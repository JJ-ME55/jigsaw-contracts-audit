// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CollectionLauncher} from "src/CollectionLauncher.sol";
import {LoomCollection} from "reference/LoomCollection.sol";

/// Stands in for the Loom NFT factory: clones the live LoomCollection implementation and makes the caller its owner,
/// which is what the launcher relies on (it then sets provenance and URI as owner).
contract MockLoomFactory {
    address public immutable impl;
    constructor(address impl_) { impl = impl_; }
    function createCollection(string calldata name, string calldata symbol, uint256 maxSupply, uint256 mintPriceWei, uint256 maxPerWallet, address creator, uint96 royaltyBps) external payable returns (address c) {
        c = Clones.clone(impl);
        LoomCollection(c).initialize(name, symbol, maxSupply, mintPriceWei, maxPerWallet, creator, royaltyBps, msg.sender);
    }
}

/// Round 8 Low 3 was fixed on the phased path only: CollectionLauncher.create(freeze = true, revealLater = false,
/// uri = "") still freezes a Loom clone on an empty base URI, for good (LoomCollection.freezeMetadata has no guard).
/// Fails on this code ("next call did not revert as expected"); passes once create() reverts NothingToFreeze for
/// freeze with an empty uri, as JigsawCollection.initialize does.
contract LoomFreezeEmptyUriTest is Test {
    address operator = makeAddr("operator");
    address safe = makeAddr("safe");
    address creator = makeAddr("creator");
    address minter = makeAddr("minter");

    function test_launcher_refuses_freeze_with_empty_uri_as_the_phased_path_does() public {
        MockLoomFactory f = new MockLoomFactory(address(new LoomCollection(safe, safe)));
        CollectionLauncher l = new CollectionLauncher(address(f), operator, safe);
        CollectionLauncher.Collection memory c = CollectionLauncher.Collection({name: "N", symbol: "S", maxSupply: 10, mintPriceWei: 0, maxPerWallet: 1, creator: creator, royaltyBps: 0});
        vm.prank(operator);
        // on this code the call succeeds and the clone is metadataFrozen with baseURI == "" and tokenURI(id) == ""
        // for every token, with setBaseURI reverting MetadataIsFrozen: nothing can ever give the tokens metadata
        vm.expectRevert(CollectionLauncher.NothingToFreeze.selector);
        l.create(c, bytes32(uint256(1)), "", false, true);
    }
}
