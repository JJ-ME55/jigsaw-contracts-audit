// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {AirdropClaim} from "src/AirdropClaim.sol";

contract MockCollection is ERC721 {
    uint256 public constant maxSupply = 10;
    constructor() ERC721("C", "C") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

/// A creator coin stand-in: only collection() and plain ERC20 are needed by AirdropClaim.
contract MockCoin is ERC20 {
    address public collection;
    constructor(address col, address to) ERC20("K", "K") { collection = col; _mint(to, 50_000_000e18); }
}

/// A marketplace escrow: holds listed NFTs, can receive ERC-721s, has no way to move ERC-20s.
contract Escrow is IERC721Receiver {
    mapping(uint256 => address) public lister;
    function onERC721Received(address, address from, uint256 id, bytes calldata) external returns (bytes4) {
        lister[id] = from;
        return this.onERC721Received.selector;
    }
    function cancel(address col, uint256 id) external {
        require(lister[id] == msg.sender);
        delete lister[id];
        ERC721(col).transferFrom(address(this), msg.sender, id);
    }
}

contract AirdropPushToEscrowTest is Test {
    AirdropClaim drop;
    MockCollection col;
    MockCoin coin;
    Escrow escrow;
    address pot = makeAddr("pot");
    address alice = makeAddr("alice");
    address griefer = makeAddr("griefer");

    function setUp() public {
        drop = new AirdropClaim(address(this), pot);
        drop.setFactory(address(this)); // this test plays the CoinFactory
        col = new MockCollection();
        escrow = new Escrow();
        col.mint(alice, 7);
        // Alice lists #7 on the escrow marketplace before the coin launches
        vm.prank(alice);
        col.safeTransferFrom(alice, address(escrow), 7);
        coin = new MockCoin(address(col), address(drop)); // the 5% lands in AirdropClaim ...
        drop.notify(address(coin)); // ... and the factory fixes the per-NFT share
    }

    /// Anyone can push #7's share to the escrow contract; the escrow cannot move ERC-20s, and once the id is
    /// marked claimed Alice can never take her share even after she takes the NFT back.
    function test_pushToContractOwnerStrandsTheShare() public {
        (,, uint256 perNft,) = drop.drops(address(coin));
        assertGt(perNft, 0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        vm.prank(griefer);
        drop.claimFor(address(coin), ids);

        // Alice delists and tries to claim herself
        vm.prank(alice);
        escrow.cancel(address(col), 7);
        assertEq(col.ownerOf(7), alice);

        vm.prank(alice);
        try drop.claim(address(coin), ids) {} catch {}

        // Expected: Alice (the NFT's beneficial owner) ends up with #7's share, or the share is still claimable by her.
        // Actual: the coin sits in the escrow contract forever and #7 is marked claimed.
        assertEq(coin.balanceOf(address(escrow)), 0, "share pushed into a contract that cannot move it");
        assertEq(coin.balanceOf(alice), perNft, "Alice never receives her share");
    }
}
