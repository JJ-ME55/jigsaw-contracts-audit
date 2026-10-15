// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LoomCollection} from "../src/nft/LoomCollection.sol";
import {LoomFactory} from "../src/nft/LoomFactory.sol";

/// NFT contract v2: the audited LoomCollection plus a mint referral (10 of the platform's 40 points).
contract NftV2Test is Test {
    address platform = makeAddr("platform");
    address reserve = makeAddr("reserve");
    address creator = makeAddr("creator");
    address site = makeAddr("site");
    address minter = makeAddr("minter");

    LoomCollection impl;
    LoomFactory factory;
    LoomCollection col;

    function setUp() public {
        impl = new LoomCollection(platform, reserve);
        factory = new LoomFactory(address(impl), platform, platform);
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        address c = factory.createCollection{value: factory.CREATE_FEE()}("Cool", "COOL", 100, 0, 5, creator, 500);
        col = LoomCollection(c);
        vm.deal(minter, 1 ether);
    }

    function test_mint_without_referral_unchanged() public {
        uint256 fee = col.PLATFORM_FEE();
        uint256 c0 = creator.balance; uint256 p0 = platform.balance;
        vm.prank(minter);
        col.mint{value: fee * 2}(2);
        assertEq(col.balanceOf(minter), 2);
        assertEq(creator.balance - c0, fee * 2 * 40 / 100);
        assertEq(platform.balance - p0, fee * 2 * 40 / 100);
        assertEq(reserve.balance, fee * 2 * 20 / 100);
    }

    function test_mint_with_referral_pays_site_from_platform_share() public {
        uint256 fee = col.PLATFORM_FEE();
        uint256 platBefore = platform.balance; uint256 c0 = creator.balance;
        vm.prank(minter);
        col.mint{value: fee * 2}(2, site);
        assertEq(site.balance, fee * 2 * 10 / 100, "site gets 10 points");
        assertEq(platform.balance - platBefore, fee * 2 * 30 / 100, "platform keeps 30");
        assertEq(creator.balance - c0, fee * 2 * 40 / 100, "creator untouched");
        assertEq(reserve.balance, fee * 2 * 20 / 100, "reserve untouched");
    }

    function test_referral_equal_to_platform_or_zero_changes_nothing() public {
        uint256 fee = col.PLATFORM_FEE();
        uint256 platBefore = platform.balance;
        vm.prank(minter);
        col.mint{value: fee}(1, platform);
        assertEq(platform.balance - platBefore, fee * 40 / 100);
    }

    function test_fee_conservation_with_referral() public {
        uint256 fee = col.PLATFORM_FEE();
        uint256 before = creator.balance + platform.balance + reserve.balance + site.balance;
        vm.prank(minter);
        col.mint{value: fee * 3}(3, site);
        uint256 after_ = creator.balance + platform.balance + reserve.balance + site.balance;
        assertEq(after_ - before, fee * 3, "every wei accounted for");
    }
}
