// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title HolderPayouts
/// @notice Snapshot-based payouts for the "fees to coin holders" and "split NFT and coin
///         holders" flywheels (Jj, 15 Oct: snapshots, no staking). Shared across coins.
///         A per-coin SnapshotForwarder delivers that coin's flywheel slice here. The
///         platform snapshots holders at a random moment, computes shares, and declares a
///         round: a merkle root, a total and a claim window. Holders claim their own.
///         Whatever a round leaves unclaimed after its window returns to the coin's
///         balance for the next round. There is no withdraw: JIG only ever leaves to a
///         proven leaf.
contract HolderPayouts is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Round {
        bytes32 root; // keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
        uint128 total;
        uint128 claimed;
        uint64 expiry;
        bool settled; // expired remainder returned to the coin's balance
    }

    IERC20 public immutable jig;
    mapping(address coin => uint256) public balance; // JIG held for a coin, not yet in a live round
    mapping(address coin => Round[]) public rounds;
    mapping(address coin => mapping(uint256 round => mapping(address account => bool))) public hasClaimed;

    event Funded(address indexed coin, address indexed from, uint256 amount);
    event RoundDeclared(address indexed coin, uint256 indexed round, bytes32 root, uint256 total, uint64 expiry);
    event Claimed(address indexed coin, uint256 indexed round, address indexed account, uint256 amount);
    event RoundSettled(address indexed coin, uint256 indexed round, uint256 returned);

    error ZeroAddress();
    error BadRound();
    error Expired();
    error NotExpired();
    error AlreadyClaimed();
    error BadProof();

    constructor(address owner_, address jig_) Ownable(owner_) {
        if (jig_ == address(0)) revert ZeroAddress();
        jig = IERC20(jig_);
    }

    /// @notice Deliver JIG for `coin`. The caller must have approved this contract. Anyone may fund.
    function fund(address coin, uint256 amount) external nonReentrant {
        if (coin == address(0)) revert ZeroAddress();
        jig.safeTransferFrom(msg.sender, address(this), amount);
        balance[coin] += amount;
        emit Funded(coin, msg.sender, amount);
    }

    /// @notice Declare a round for `coin` from its balance. Owner (the platform) only.
    function declare(address coin, bytes32 root, uint256 total, uint64 expiry) external onlyOwner returns (uint256 round) {
        if (root == bytes32(0) || total == 0 || total > type(uint128).max || expiry <= block.timestamp) revert BadRound();
        if (total > balance[coin]) revert BadRound();
        balance[coin] -= total;
        round = rounds[coin].length;
        rounds[coin].push(Round({root: root, total: uint128(total), claimed: 0, expiry: expiry, settled: false}));
        emit RoundDeclared(coin, round, root, total, expiry);
    }

    function claim(address coin, uint256 round, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        Round storage r = rounds[coin][round];
        if (block.timestamp > r.expiry) revert Expired();
        if (hasClaimed[coin][round][account]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (!MerkleProof.verify(proof, r.root, leaf)) revert BadProof();
        if (r.claimed + amount > r.total) revert BadRound();
        hasClaimed[coin][round][account] = true;
        r.claimed += uint128(amount);
        jig.safeTransfer(account, amount);
        emit Claimed(coin, round, account, amount);
    }

    /// @notice After a round's window, return what was not claimed to the coin's balance. Anyone may call.
    function settle(address coin, uint256 round) external nonReentrant returns (uint256 returned) {
        Round storage r = rounds[coin][round];
        if (block.timestamp <= r.expiry) revert NotExpired();
        if (r.settled) return 0;
        r.settled = true;
        returned = r.total - r.claimed;
        balance[coin] += returned;
        emit RoundSettled(coin, round, returned);
    }

    function roundCount(address coin) external view returns (uint256) {
        return rounds[coin].length;
    }
}
