// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {HolderDrip} from "../src/HolderDrip.sol";

contract DripJig is ERC20 {
    constructor() ERC20("J", "J") {}
    function mint(address a, uint256 v) external { _mint(a, v); }
}

contract DripNft is ERC721 {
    uint256 public totalSupply;
    constructor() ERC721("N", "N") {}
    function mint(address to) external { _mint(to, ++totalSupply); }
}

/// Stands in for CreatorFeeHook: HolderDrip reads jig() and pot() and calls claim().
contract DripHookStub {
    DripJig public jig;
    address public pot = address(0xB0B);
    constructor(DripJig j) { jig = j; }
    function claim() external pure returns (uint256) { return 0; }
}

/// Pre-audit review, 16 Oct 2026 (High): a token minted after a pull, burned and marked before the next pull was
/// subtracted from a supply that never contained it, so the drip promised more than it held and pull() later reverted
/// for good. Burns are folded against the supply the pull spreads over.
contract HolderDripBurnsTest is Test {
    function test_a_burn_above_the_spread_supply_does_not_shrink_it() public {
        DripJig j = new DripJig(); DripHookStub h = new DripHookStub(j); DripNft n = new DripNft();
        for (uint256 i; i < 10; i++) n.mint(address(uint160(100 + i)));
        HolderDrip d = new HolderDrip(address(h), address(n));
        d.pull(); // records supply 10
        n.mint(address(this)); // token 11
        n.transferFrom(address(this), d.DEAD(), 11);
        d.markBurned(11);
        j.mint(address(d), 90e18);
        d.pull(); // spreads 90 over the 10 tokens that existed at the previous pull
        uint256 sum;
        for (uint256 i = 1; i <= 10; i++) sum += d.owed(i);
        assertLe(sum, 90e18, "never promises more than it holds");
        assertApproxEqAbs(d.owed(1), 9e18, 10, "each of the 10 gets 9");
        for (uint256 i = 1; i <= 10; i++) {
            uint256[] memory ids = new uint256[](1); ids[0] = i;
            vm.prank(address(uint160(99 + i)));
            d.claim(ids);
        }
        assertLe(d.paidOut(), d.accounted(), "solvent");
        j.mint(address(d), 10e18);
        d.pull(); // keeps working: the burn above is folded in when its supply is spread
        assertEq(d.burnedCount(), 1);
    }
}
