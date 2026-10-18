// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ILoomFactory {
    function createCollection(
        string calldata name,
        string calldata symbol,
        uint256 maxSupply,
        uint256 mintPriceWei,
        uint256 maxPerWallet,
        address creator,
        uint96 royaltyBps
    ) external payable returns (address);
}

interface ILoomCollectionOwner {
    function setProvenanceHash(bytes32 hash) external;
    function setUnrevealedURI(string calldata uri) external;
    function setBaseURI(string calldata uri) external;
    function freezeMetadata() external;
    function transferOwnership(address newOwner) external;
}

/// @title CollectionLauncher
/// @notice Creates an NFT collection through the Loom factory and commits its provenance and its first URI in the same
///         transaction, then hands ownership to the operator (Ownable2Step: the operator calls acceptOwnership()).
///         A clone is mintable from the moment it exists and setProvenanceHash refuses once anything is minted, so
///         creating and committing in separate transactions let anyone mint in between and block the commitment for
///         good (replica review, 17 Oct). Only the operator may call create(); it holds nothing between calls.
contract CollectionLauncher {
    ILoomFactory public immutable factory;
    address public immutable operator;
    address public immutable admin; // the Safe: re-offers a collection whose pending owner can no longer accept

    struct Collection {
        string name;
        string symbol;
        uint256 maxSupply;
        uint256 mintPriceWei;
        uint256 maxPerWallet;
        address creator;
        uint96 royaltyBps;
    }

    event Launched(address indexed collection, bytes32 provenance, bool revealLater);

    error ZeroAddress();
    error NotOperator();
    error NotAdmin();
    error BadProvenance();
    error NothingToFreeze();

    constructor(address factory_, address operator_, address admin_) {
        if (factory_ == address(0) || operator_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        factory = ILoomFactory(factory_);
        operator = operator_;
        admin = admin_;
    }

    /// @param provenance the hash of the art in its final order, committed before any token can exist
    /// @param uri the unrevealed placeholder (revealLater) or the final base URI
    /// @param freeze for an immediate reveal: freeze the metadata in this transaction (ipfs:// base URI; final audit,
    ///        17 Oct). A reveal-later collection is frozen by the reveal instead.
    /// @dev msg.value is the factory's creation fee, passed through unchanged.
    function create(Collection calldata c, bytes32 provenance, string calldata uri, bool revealLater, bool freeze)
        external
        payable
        returns (address collection)
    {
        if (msg.sender != operator) revert NotOperator();
        if (provenance == bytes32(0)) revert BadProvenance(); // LoomCollection would treat a zero hash as committed forever
        if (freeze && revealLater) revert NothingToFreeze(); // the reveal freezes it; as JigsawCollection (swarm round 8, Info 7)
        collection = factory.createCollection{value: msg.value}(
            c.name, c.symbol, c.maxSupply, c.mintPriceWei, c.maxPerWallet, c.creator, c.royaltyBps
        );
        ILoomCollectionOwner(collection).setProvenanceHash(provenance);
        if (revealLater) ILoomCollectionOwner(collection).setUnrevealedURI(uri);
        else ILoomCollectionOwner(collection).setBaseURI(uri);
        if (freeze && !revealLater) ILoomCollectionOwner(collection).freezeMetadata();
        ILoomCollectionOwner(collection).transferOwnership(operator);
        emit Launched(collection, provenance, revealLater);
    }

    /// @notice Offer a collection this launcher still owns to `to`. For a collection created but never accepted (the
    ///         operator key rotated or lost in between); only the admin may call it. A collection the launcher no
    ///         longer owns reverts in transferOwnership.
    function reoffer(address collection, address to) external {
        if (msg.sender != admin) revert NotAdmin();
        if (to == address(0)) revert ZeroAddress();
        ILoomCollectionOwner(collection).transferOwnership(to);
    }
}
