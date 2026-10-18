// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface ICoinCollection {
    function collection() external view returns (address);
}

/// @title AirdropClaim
/// @notice Shared claim for every creator coin's 5% airdrop to its collection's NFT holders (Build Spec §4), entirely
///         on chain (Jj, 17 Oct: no snapshot, no root, no key). CoinFactory sends each coin's 5% here at launch and
///         calls notify(), which fixes the share per NFT: the 5% divided by the collection's maxSupply (or, for a
///         collection without one, its totalSupply at launch). Whoever owns NFT #id when claiming takes that id's
///         share, once per id, for CLAIM_WINDOW after launch; afterwards anyone may send what is left (shares
///         never claimed, ids never minted, rounding dust) to the pot. The owner's only power is binding the
///         factory once; tokens only ever go to NFT owners or to the pot.
contract AirdropClaim is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant CLAIM_WINDOW = 30 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Drop {
        address collection;
        uint64 opensAt; // launch time; claims run until opensAt + CLAIM_WINDOW
        uint256 perNft; // coin per token id
        uint256 maxId; // ids 1..maxId can claim
    }

    address public immutable pot;
    address public factory; // set once by the owner; the only caller of notify()
    mapping(address coin => Drop) public drops;
    mapping(address coin => mapping(uint256 id => bool)) public claimed;

    event DropOpened(address indexed coin, address indexed collection, uint256 perNft, uint256 maxId);
    event Claimed(address indexed coin, address indexed account, uint256 nfts, uint256 amount);
    event Pushed(address indexed coin, uint256 nfts, uint256 amount);
    event Swept(address indexed coin, uint256 amount);

    error ZeroAddress();
    error NotOpen();
    error Expired();
    error NotExpired();
    error AlreadyClaimed();
    error NotOwnerOf(uint256 id);
    error BadId(uint256 id);
    error NotFactory();
    error FactorySet();

    constructor(address owner_, address pot_) Ownable(owner_) {
        if (pot_ == address(0)) revert ZeroAddress();
        pot = pot_;
    }

    /// @notice Bind the coin factory. Once only.
    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0) || factory_ == address(0)) revert FactorySet();
        factory = factory_;
    }

    /// @notice Called by the factory right after it delivers a coin's share: fixes the per-NFT amount.
    function notify(address coin) external {
        if (msg.sender != factory) revert NotFactory();
        if (drops[coin].opensAt != 0) return;
        address col = ICoinCollection(coin).collection();
        uint256 maxId = _supplyCap(col);
        uint256 total = IERC20(coin).balanceOf(address(this)); // the coin was created in this same transaction: its only balance here is the 5%
        drops[coin] = Drop({collection: col, opensAt: uint64(block.timestamp), perNft: maxId == 0 ? 0 : total / maxId, maxId: maxId});
        emit DropOpened(coin, col, maxId == 0 ? 0 : total / maxId, maxId);
    }

    /// @notice Claim `coin`'s share for every id in `ids` the caller owns.
    function claim(address coin, uint256[] calldata ids) external nonReentrant returns (uint256 amount) {
        Drop storage d = drops[coin];
        if (d.opensAt == 0 || d.perNft == 0) revert NotOpen();
        if (block.timestamp > d.opensAt + CLAIM_WINDOW) revert Expired();
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            if (id == 0 || id > d.maxId) revert BadId(id);
            if (claimed[coin][id]) revert AlreadyClaimed();
            if (IERC721(d.collection).ownerOf(id) != msg.sender) revert NotOwnerOf(id);
            claimed[coin][id] = true;
        }
        amount = d.perNft * ids.length;
        IERC20(coin).safeTransfer(msg.sender, amount);
        emit Claimed(coin, msg.sender, ids.length, amount);
    }

    /// @notice Push airdrop (Jj, 17 Oct): send each id's share to the NFT's current owner. Anyone may call it (the
    ///         keeper does, in batches, so the airdrop lands without holders doing anything). Ids already claimed, out
    ///         of range, not minted or owned by the dead address are skipped, never reverted, so a batch cannot fail
    ///         on a race with a holder's own claim. Burned ids keep their share for the pot.
    function claimFor(address coin, uint256[] calldata ids) external nonReentrant returns (uint256 sent) {
        Drop storage d = drops[coin];
        if (d.opensAt == 0 || d.perNft == 0) revert NotOpen();
        if (block.timestamp > d.opensAt + CLAIM_WINDOW) revert Expired();
        uint256 pushed;
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            if (id == 0 || id > d.maxId || claimed[coin][id]) continue;
            (bool ok, bytes memory ret) = d.collection.staticcall(abi.encodeCall(IERC721.ownerOf, (id)));
            if (!ok || ret.length != 32) continue; // not minted
            address owner_ = abi.decode(ret, (address));
            if (owner_ == address(0) || owner_ == DEAD) continue;
            // never push into a contract (escrow, vault, bridge, smart wallet): it may not be able to move the coin,
            // and the id would be marked claimed for good. Those owners claim themselves (swarm round 8, Medium 2)
            if (owner_.code.length != 0) continue;
            claimed[coin][id] = true;
            IERC20(coin).safeTransfer(owner_, d.perNft);
            pushed++;
        }
        sent = d.perNft * pushed;
        emit Pushed(coin, pushed, sent);
    }

    /// @notice What `ids` could claim now (0 for an id already claimed or out of range; ownership not checked).
    function claimable(address coin, uint256[] calldata ids) external view returns (uint256 amount) {
        Drop storage d = drops[coin];
        if (d.opensAt == 0 || block.timestamp > d.opensAt + CLAIM_WINDOW) return 0;
        for (uint256 i; i < ids.length; i++) if (ids[i] != 0 && ids[i] <= d.maxId && !claimed[coin][ids[i]]) amount += d.perNft;
    }

    /// @notice After the claim window, anyone may send what is left of `coin` here to the pot.
    function sweep(address coin) external nonReentrant returns (uint256 amount) {
        Drop storage d = drops[coin];
        if (d.opensAt == 0) revert NotOpen();
        if (block.timestamp <= d.opensAt + CLAIM_WINDOW) revert NotExpired();
        amount = IERC20(coin).balanceOf(address(this));
        if (amount > 0) IERC20(coin).safeTransfer(pot, amount);
        emit Swept(coin, amount);
    }

    /// @dev maxSupply() if the collection has one, else totalSupply(), else 0 (nothing claimable; all swept later).
    function _supplyCap(address col) internal view returns (uint256) {
        (bool ok, bytes memory ret) = col.staticcall(abi.encodeWithSignature("maxSupply()"));
        if (ok && ret.length == 32) return abi.decode(ret, (uint256));
        (ok, ret) = col.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (ok && ret.length == 32) return abi.decode(ret, (uint256));
        return 0;
    }
}
