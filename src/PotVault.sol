// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title PotVault, the JIG pot
/// @notice Receives the 20% mint-fee reserve (ETH), the pot slice of every creator-coin
///         fee (JIG) and 10% of JIG supply at birth. Everything accrues here and is
///         visible on chain. Payouts exist as merkle distributions but are switched OFF
///         until both founders enable them after legal advice (spec 3f). Nothing can
///         leave the vault except through a declared distribution, claimed by holders
///         (pull, never push). The owner cannot withdraw to itself.
contract PotVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Distribution {
        address token; // address(0) = ETH
        bytes32 root; // merkle root of keccak256(abi.encode(account, amount))
        uint128 total;
        uint128 claimed;
        uint64 expiry; // after this, unclaimed stays in the vault for a later distribution
    }

    bool public payoutsEnabled;
    Distribution[] public distributions;
    mapping(uint256 id => mapping(address account => bool)) public hasClaimed;

    event Received(address indexed from, address indexed token, uint256 amount);
    event PayoutsEnabled();
    event DistributionDeclared(uint256 indexed id, address indexed token, bytes32 root, uint256 total, uint64 expiry);
    event Claimed(uint256 indexed id, address indexed account, uint256 amount);

    error PayoutsOff();
    error BadDistribution();
    error AlreadyClaimed();
    error Expired();
    error BadProof();
    error EthSendFailed();

    constructor(address owner_) Ownable(owner_) {}

    receive() external payable {
        emit Received(msg.sender, address(0), msg.value);
    }

    /// @notice Record an ERC-20 deposit. Tokens sent by plain transfer still count; this just emits.
    function notifyDeposit(address token, uint256 amount) external {
        emit Received(msg.sender, token, amount);
    }

    /// @notice One-way switch. Flip only after legal advice; both founders behind the owner key.
    function enablePayouts() external onlyOwner {
        payoutsEnabled = true;
        emit PayoutsEnabled();
    }

    /// @notice Declare a distribution of `total` of `token` to the accounts in the merkle tree.
    ///         Funds stay in the vault until each holder claims.
    function declare(address token, bytes32 root, uint256 total, uint64 expiry) external onlyOwner returns (uint256 id) {
        if (!payoutsEnabled) revert PayoutsOff();
        if (root == bytes32(0) || total == 0 || total > type(uint128).max || expiry <= block.timestamp) revert BadDistribution();
        if (total > available(token)) revert BadDistribution();
        id = distributions.length;
        distributions.push(Distribution({token: token, root: root, total: uint128(total), claimed: 0, expiry: expiry}));
        emit DistributionDeclared(id, token, root, total, expiry);
    }

    function claim(uint256 id, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        Distribution storage d = distributions[id];
        if (block.timestamp > d.expiry) revert Expired();
        if (hasClaimed[id][account]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (!MerkleProof.verify(proof, d.root, leaf)) revert BadProof();
        if (d.claimed + amount > d.total) revert BadDistribution();

        hasClaimed[id][account] = true;
        d.claimed += uint128(amount);
        emit Claimed(id, account, amount);

        if (d.token == address(0)) {
            (bool ok,) = account.call{value: amount}("");
            if (!ok) revert EthSendFailed();
        } else {
            IERC20(d.token).safeTransfer(account, amount);
        }
    }

    /// @notice Balance of `token` not yet reserved by a live distribution.
    function available(address token) public view returns (uint256) {
        uint256 bal = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        uint256 reserved;
        for (uint256 i; i < distributions.length; i++) {
            Distribution storage d = distributions[i];
            if (d.token == token && block.timestamp <= d.expiry) reserved += d.total - d.claimed;
        }
        return bal > reserved ? bal - reserved : 0;
    }

    function distributionCount() external view returns (uint256) {
        return distributions.length;
    }
}
