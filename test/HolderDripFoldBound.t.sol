// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HolderDrip} from "../src/HolderDrip.sol";
import {DripJig, DripNft, DripHookStub} from "./HolderDripBurns.t.sol";

/// Final audit (17 Oct), Low 10: _foldBurns folded every burn above the previous supply in one pull, so a few hundred
/// such burns pushed pull() over the keeper's gas cap and thousands over a block. At most MAX_FOLD are folded per pull;
/// the rest wait for later pulls, and the drip stays solvent meanwhile.
contract HolderDripFoldBoundTest is Test {
    function test_many_burns_above_the_supply_fold_in_bounded_pulls() public {
        DripJig j = new DripJig(); DripHookStub h = new DripHookStub(j); DripNft n = new DripNft();
        for (uint256 i; i < 10; i++) n.mint(address(uint160(100 + i)));
        HolderDrip d = new HolderDrip(address(h), address(n)); // lastSupply 10
        for (uint256 i; i < 300; i++) { n.mint(address(this)); uint256 id = n.totalSupply(); n.transferFrom(address(this), d.DEAD(), id); d.markBurned(id); }
        j.mint(address(d), 1e18);
        d.pull(); // spreads over 10, records 310
        j.mint(address(d), 1e18);
        uint256 g = gasleft(); d.pull(); uint256 used = g - gasleft();
        assertLt(used, 1_500_000, "one pull stays far below the keeper's gas cap");
        assertEq(d.burnedCount(), d.MAX_FOLD(), "folds at most MAX_FOLD per pull");
        for (uint256 k; k < 10; k++) { j.mint(address(d), 1e18); d.pull(); }
        assertEq(d.burnedCount(), 300, "every burn is folded in the end");
        uint256 sum; for (uint256 i = 1; i <= 10; i++) sum += d.owed(i);
        assertLe(sum, d.accounted() - d.paidOut(), "never promises more than it holds");
    }
}
