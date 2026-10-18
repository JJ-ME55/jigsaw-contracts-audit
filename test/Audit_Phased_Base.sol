// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JigsawCollection} from "../src/JigsawCollection.sol";
import {JigsawCollectionFactory} from "../src/JigsawCollectionFactory.sol";

abstract contract PhasedAuditBase is Test {
    uint64 constant T0 = 1_800_000_000;
    uint256 constant FEE = 0.0005 ether;
    address platform = makeAddr("platform");
    address operator = makeAddr("operator");
    address safe = makeAddr("safe");
    address minter = makeAddr("minter");
    JigsawCollectionFactory factory;

    function _cfg(address creator_, uint256 supply, uint256 cap) internal pure returns (JigsawCollection.Config memory) {
        return JigsawCollection.Config({name: "A", symbol: "A", maxSupply: supply, maxPerWallet: cap, creator: creator_, royaltyBps: 0});
    }

    function _deploy() internal {
        vm.warp(T0 - 1 days);
        JigsawCollection impl = new JigsawCollection(platform, platform);
        factory = new JigsawCollectionFactory(address(impl), operator, safe);
        vm.deal(minter, 100 ether);
        vm.deal(operator, 100 ether);
    }

    function _create(JigsawCollection.Config memory c, JigsawCollection.Phase[] memory ps, bool revealLater, bool freeze, string memory uri)
        internal
        returns (JigsawCollection)
    {
        vm.prank(operator);
        return JigsawCollection(factory.create(c, ps, keccak256("art"), uri, revealLater, freeze));
    }

    function _leaf(address a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a))));
    }
}
