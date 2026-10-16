// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HolderDrip} from "../src/HolderDrip.sol";
import {DripJig, DripNft, DripHookStub} from "./HolderDripBurns.t.sol";

/// Replica review, 17 Oct 2026 (Low): the first pull spread over the supply at that pull, so tokens minted after the
/// module existed (and after fees accrued) shared in fees from before they existed. The supply is now recorded when
/// the module is deployed, so the first pull spreads over the tokens that existed then.
contract HolderDripFirstPullTest is Test {
    function test_tokens_minted_before_the_first_pull_do_not_share_earlier_fees() public {
        DripJig j = new DripJig(); DripHookStub h = new DripHookStub(j); DripNft n = new DripNft();
        for (uint256 i; i < 4; i++) n.mint(address(uint160(100 + i)));
        HolderDrip d = new HolderDrip(address(h), address(n)); // 4 tokens when the module goes live
        j.mint(address(d), 40e18); // fees accrue
        for (uint256 i; i < 4; i++) n.mint(address(0xBAD)); // an attacker mints 4 more, then pulls
        d.pull();
        assertApproxEqAbs(d.owed(1), 10e18, 10, "the 4 original tokens share the 40");
        assertEq(d.owed(5), 0, "a token minted after the fees gets none of them");
        j.mint(address(d), 80e18);
        d.pull(); // the next pull spreads over all 8
        assertApproxEqAbs(d.owed(5), 10e18, 10, "late tokens earn from the next pull on");
    }

    function test_an_empty_collection_holds_fees_until_tokens_exist() public {
        DripJig j = new DripJig(); DripHookStub h = new DripHookStub(j); DripNft n = new DripNft();
        HolderDrip d = new HolderDrip(address(h), address(n));
        j.mint(address(d), 10e18);
        n.mint(address(0xA));
        assertEq(d.pull(), 0, "nothing spread over an empty supply");
        assertEq(d.undistributed(), 10e18, "kept for the tokens that follow");
        d.pull(); // now spreads over token 1
        assertApproxEqAbs(d.owed(1), 10e18, 10);
    }
}
