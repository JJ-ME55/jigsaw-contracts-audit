// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CollectionLauncher} from "../src/CollectionLauncher.sol";

interface IFactoryView {
    function CREATE_FEE() external view returns (uint256);
    function createCollection(string calldata, string calldata, uint256, uint256, uint256, address, uint96)
        external
        payable
        returns (address);
}

interface ICollectionView {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
    function provenanceHash() external view returns (bytes32);
    function provenanceSet() external view returns (bool);
    function unrevealedURI() external view returns (string memory);
    function baseURI() external view returns (string memory);
    function mintPriceWei() external view returns (uint256);
    function mint(uint256) external payable;
    function setProvenanceHash(bytes32) external;
    function totalSupply() external view returns (uint256);
}

/// The live Loom factory on Sepolia: a separate create + setProvenanceHash can be blocked by one mint in between;
/// CollectionLauncher commits in the same transaction, so there is no gap (replica review, 17 Oct).
contract CollectionLauncherForkTest is Test {
    address constant FACTORY = 0xbE4d0c08C60bB459e8bF19a4524eB6dCBD87F50F;
    address op = makeAddr("operator");
    address creator = makeAddr("creator");
    address minter = makeAddr("minter");
    CollectionLauncher launcher;

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC", string("https://ethereum-sepolia-rpc.publicnode.com")));
        launcher = new CollectionLauncher(FACTORY, op, makeAddr("safe"));
        vm.deal(op, 10 ether);
        vm.deal(minter, 10 ether);
    }

    function _c() internal view returns (CollectionLauncher.Collection memory) {
        return CollectionLauncher.Collection("Race Test", "RACE", 100, 0, 5, creator, 500);
    }

    function _mintOne(address col) internal {
        // LoomCollection charges exactly (mintPriceWei + PLATFORM_FEE) per token; PLATFORM_FEE is 0.0005 ether
        uint256 price = ICollectionView(col).mintPriceWei() + 0.0005 ether;
        vm.prank(minter);
        ICollectionView(col).mint{value: price}(1);
    }

    function test_the_old_two_step_launch_can_be_blocked_by_one_mint() public {
        uint256 fee = IFactoryView(FACTORY).CREATE_FEE();
        vm.prank(op);
        address col = IFactoryView(FACTORY).createCollection{value: fee}("Race Test", "RACE", 100, 0, 5, creator, 500);
        _mintOne(col); // an outsider in the next block
        vm.prank(op);
        vm.expectRevert(); // MintingAlreadyStarted
        ICollectionView(col).setProvenanceHash(keccak256("art"));
    }

    function test_launcher_commits_before_any_mint_and_hands_ownership_to_the_operator() public {
        uint256 fee = IFactoryView(FACTORY).CREATE_FEE();
        vm.prank(op);
        address col = launcher.create{value: fee}(_c(), keccak256("art"), "ipfs://placeholder.json", true, false);
        assertTrue(ICollectionView(col).provenanceSet(), "provenance committed in the creating transaction");
        assertEq(ICollectionView(col).provenanceHash(), keccak256("art"));
        assertEq(ICollectionView(col).unrevealedURI(), "ipfs://placeholder.json");
        assertEq(ICollectionView(col).totalSupply(), 0);
        assertEq(ICollectionView(col).pendingOwner(), op, "operator must accept");
        vm.prank(op);
        ICollectionView(col).acceptOwnership();
        assertEq(ICollectionView(col).owner(), op);
        _mintOne(col); // minting works afterwards
        assertEq(ICollectionView(col).totalSupply(), 1);
    }

    function test_launcher_sets_the_base_uri_for_an_immediate_reveal() public {
        uint256 fee = IFactoryView(FACTORY).CREATE_FEE();
        vm.prank(op);
        address col = launcher.create{value: fee}(_c(), keccak256("art"), "ipfs://meta/", false, false);
        assertEq(ICollectionView(col).baseURI(), "ipfs://meta/");
        assertTrue(ICollectionView(col).provenanceSet());
    }

    function test_an_immediate_reveal_can_be_frozen_at_creation() public {
        uint256 fee = IFactoryView(FACTORY).CREATE_FEE();
        vm.prank(op);
        address col = launcher.create{value: fee}(_c(), keccak256("art"), "ipfs://meta/", false, true);
        (bool ok, bytes memory ret) = col.staticcall(abi.encodeWithSignature("metadataFrozen()"));
        assertTrue(ok && abi.decode(ret, (bool)), "frozen in the creating transaction");
        assertEq(ICollectionView(col).baseURI(), "ipfs://meta/");
    }

    function test_only_the_operator_can_launch() public {
        uint256 fee = IFactoryView(FACTORY).CREATE_FEE();
        vm.deal(minter, 10 ether);
        vm.prank(minter);
        vm.expectRevert(CollectionLauncher.NotOperator.selector);
        launcher.create{value: fee}(_c(), keccak256("art"), "ipfs://x/", false, false);
    }
}

/// Final audit (17 Oct): Info 19, a zero provenance is refused; Low 7, a collection whose pending owner cannot accept
/// (operator key rotated or lost) can be re-offered by the admin (the Safe), and by nobody else.
contract CollectionLauncherAdminForkTest is Test {
    address constant FACTORY = 0xbE4d0c08C60bB459e8bF19a4524eB6dCBD87F50F;
    address op = makeAddr("operator");
    address safe = makeAddr("safe");
    address op2 = makeAddr("operator2");
    CollectionLauncher launcher;

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC", string("https://ethereum-sepolia-rpc.publicnode.com")));
        launcher = new CollectionLauncher(FACTORY, op, safe);
        vm.deal(op, 10 ether);
    }

    function _c() internal returns (CollectionLauncher.Collection memory) {
        return CollectionLauncher.Collection("Admin Test", "ADM", 100, 0, 5, makeAddr("creator"), 500);
    }

    function test_zero_provenance_is_refused() public {
        uint256 fee = IFactoryView(FACTORY).CREATE_FEE();
        vm.prank(op);
        vm.expectRevert(CollectionLauncher.BadProvenance.selector);
        launcher.create{value: fee}(_c(), bytes32(0), "ipfs://x/", false, false);
    }

    function test_admin_reoffers_a_stranded_collection_and_nobody_else_can() public {
        uint256 fee = IFactoryView(FACTORY).CREATE_FEE();
        vm.prank(op);
        address col = launcher.create{value: fee}(_c(), keccak256("art"), "ipfs://p.json", true, false);
        vm.prank(op2);
        vm.expectRevert(CollectionLauncher.NotAdmin.selector);
        launcher.reoffer(col, op2);
        vm.prank(op);
        vm.expectRevert(CollectionLauncher.NotAdmin.selector);
        launcher.reoffer(col, op2);
        vm.prank(safe);
        launcher.reoffer(col, op2);
        assertEq(ICollectionView(col).pendingOwner(), op2);
        vm.prank(op2);
        ICollectionView(col).acceptOwnership();
        assertEq(ICollectionView(col).owner(), op2);
    }
}
