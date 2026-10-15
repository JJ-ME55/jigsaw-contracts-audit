// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title AirdropClaim
/// @notice Shared merkle claim for every creator coin's 5% airdrop to its collection's
///         NFT holders (Build Spec §4). CoinFactory sends each coin's 5% here at launch.
///         The owner (platform) then sets one root per coin from a holder snapshot, with
///         a claim window. Leftovers after the window go to the pot, as does a share whose drop
///         is never set within 7 days. The owner chooses recipients through the root but has
///         no withdraw path: tokens only ever go to proven leaves or to the pot.
contract AirdropClaim is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Drop {
        bytes32 root; // keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
        uint128 total;
        uint128 claimed;
        uint64 expiry;
    }

    address public immutable pot;
    address public factory; // set once by the owner; the only caller of notify()
    uint64 public constant UNSET_WINDOW = 7 days;
    mapping(address coin => Drop) public drops;
    mapping(address coin => uint64) public receivedAt; // when the factory delivered a coin's share
    mapping(address coin => mapping(address account => bool)) public hasClaimed;

    event DropSet(address indexed coin, bytes32 root, uint256 total, uint64 expiry);
    event Claimed(address indexed coin, address indexed account, uint256 amount);
    event Swept(address indexed coin, uint256 amount);

    error ZeroAddress();
    error AlreadySet();
    error BadDrop();
    error NotOpen();
    error Expired();
    error NotExpired();
    error AlreadyClaimed();
    error BadProof();
    error NotUnset();
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

    /// @notice Called by the factory when a coin's share arrives, starting the unset-drop clock.
    function notify(address coin) external {
        if (msg.sender != factory) revert NotFactory();
        if (receivedAt[coin] == 0) receivedAt[coin] = uint64(block.timestamp);
    }

    /// @notice If no drop was ever set for `coin` within UNSET_WINDOW of delivery, anyone may send its share to the pot.
    function sweepUnset(address coin) external nonReentrant returns (uint256 amount) {
        if (drops[coin].root != bytes32(0) || receivedAt[coin] == 0 || block.timestamp <= receivedAt[coin] + UNSET_WINDOW) revert NotUnset();
        amount = IERC20(coin).balanceOf(address(this));
        if (amount > 0) IERC20(coin).safeTransfer(pot, amount);
        emit Swept(coin, amount);
    }

    /// @notice Set a coin's drop once. `total` may not exceed what this contract holds of the coin.
    function setDrop(address coin, bytes32 root, uint256 total, uint64 expiry) external onlyOwner {
        if (drops[coin].root != bytes32(0)) revert AlreadySet();
        if (root == bytes32(0) || total == 0 || total > type(uint128).max || expiry <= block.timestamp) revert BadDrop();
        if (total > IERC20(coin).balanceOf(address(this))) revert BadDrop();
        drops[coin] = Drop({root: root, total: uint128(total), claimed: 0, expiry: expiry});
        emit DropSet(coin, root, total, expiry);
    }

    function claim(address coin, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        Drop storage d = drops[coin];
        if (d.root == bytes32(0)) revert NotOpen();
        if (block.timestamp > d.expiry) revert Expired();
        if (hasClaimed[coin][account]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (!MerkleProof.verify(proof, d.root, leaf)) revert BadProof();
        if (d.claimed + amount > d.total) revert BadDrop();
        hasClaimed[coin][account] = true;
        d.claimed += uint128(amount);
        IERC20(coin).safeTransfer(account, amount);
        emit Claimed(coin, account, amount);
    }

    /// @notice After expiry, anyone may send the unclaimed remainder to the pot.
    function sweep(address coin) external nonReentrant returns (uint256 amount) {
        Drop storage d = drops[coin];
        if (d.root == bytes32(0)) revert NotOpen();
        if (block.timestamp <= d.expiry) revert NotExpired();
        amount = IERC20(coin).balanceOf(address(this));
        if (amount > 0) IERC20(coin).safeTransfer(pot, amount);
        emit Swept(coin, amount);
    }
}
