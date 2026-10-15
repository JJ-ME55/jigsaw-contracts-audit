// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LoomCollection} from "./LoomCollection.sol";

/// @title LoomFactory
/// @notice Permissionless, atomic creation of initialized Loom collection clones.
/// @dev The pauser can only pause/unpause creation. The implementation and fee recipient cannot change.
contract LoomFactory is Pausable, ReentrancyGuard {
    uint256 public constant CREATE_FEE = 0.002 ether;
    uint256 public constant MAX_PAGE_SIZE = 100;

    address public immutable implementation;
    address public immutable PLATFORM;
    address public immutable pauser;
    address[] public collections;
    mapping(address collection => bool registered) public isCollection;

    error ZeroAddress();
    error UnauthorizedPauser();
    error IncorrectCreateFee(uint256 expected, uint256 actual);
    error InvalidImplementation();
    error PlatformMismatch();
    error ETHTransferFailed(address recipient);
    error PageTooLarge();

    event CollectionCreated(address indexed collection, address indexed owner, string name, uint256 maxSupply);

    /// @dev Only value validation here; the launch executes constructors on an empty chain.
    constructor(address implementation_, address platform, address pauser_) {
        if (implementation_ == address(0) || platform == address(0) || pauser_ == address(0)) revert ZeroAddress();
        implementation = implementation_;
        PLATFORM = platform;
        pauser = pauser_;
    }

    function createCollection(
        string calldata name,
        string calldata symbol,
        uint256 maxSupply,
        uint256 mintPriceWei,
        uint256 maxPerWallet,
        address creator,
        uint96 royaltyBps
    ) external payable nonReentrant whenNotPaused returns (address collection) {
        if (msg.value != CREATE_FEE) revert IncorrectCreateFee(CREATE_FEE, msg.value);
        if (implementation.code.length == 0) revert InvalidImplementation();
        if (LoomCollection(implementation).PLATFORM() != PLATFORM) revert PlatformMismatch();

        collection = Clones.clone(implementation);
        LoomCollection(collection)
            .initialize(name, symbol, maxSupply, mintPriceWei, maxPerWallet, creator, royaltyBps, msg.sender);
        collections.push(collection);
        isCollection[collection] = true;
        emit CollectionCreated(collection, msg.sender, name, maxSupply);

        (bool success,) = payable(PLATFORM).call{value: CREATE_FEE}("");
        if (!success) revert ETHTransferFailed(PLATFORM);
    }

    function collectionCount() external view returns (uint256) {
        return collections.length;
    }

    /// @notice Bounded pagination in creation order. Offsets past the end return an empty page.
    function getCollections(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        if (limit > MAX_PAGE_SIZE) revert PageTooLarge();
        uint256 count = collections.length;
        if (offset >= count) return new address[](0);
        uint256 size = count - offset;
        if (limit < size) size = limit;
        page = new address[](size);
        for (uint256 i; i < size; ++i) {
            page[i] = collections[offset + i];
        }
    }

    function pause() external {
        if (msg.sender != pauser) revert UnauthorizedPauser();
        _pause();
    }

    function unpause() external {
        if (msg.sender != pauser) revert UnauthorizedPauser();
        _unpause();
    }
}
