// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {JigsawCollection} from "./JigsawCollection.sol";

/// @title JigsawCollectionFactory
/// @notice Makes JigsawCollection clones (phased mints, 17 Oct) and keeps the registry the coin side checks
///         (`isCollection`). The clone is configured in the creating transaction (provenance, first URI, phases,
///         optional freeze) and owned by the operator from the start, so no mint can come before the commitment and
///         there is no ownership hand-over to accept. Only the operator (the back end) creates; the owner (the Safe)
///         may change the operator and the implementation. Collections already made keep the implementation they
///         were cloned from (no upgrades).
contract JigsawCollectionFactory is Ownable2Step {
    address public implementation;
    address public operator;
    mapping(address collection => bool) public isCollection;
    address[] public collections;

    event CollectionCreated(address indexed collection, address indexed creator, bytes32 provenance, bool revealLater);
    event OperatorSet(address operator);
    event ImplementationSet(address implementation);

    error ZeroAddress();
    error NotOperator();
    error NoCode();

    constructor(address implementation_, address operator_, address owner_) Ownable(owner_) {
        if (implementation_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        if (implementation_.code.length == 0) revert NoCode();
        implementation = implementation_;
        operator = operator_;
        emit ImplementationSet(implementation_);
        emit OperatorSet(operator_);
    }

    function create(
        JigsawCollection.Config calldata c,
        JigsawCollection.Phase[] calldata phases,
        bytes32 provenance,
        string calldata uri,
        bool revealLater,
        bool freeze
    ) external returns (address collection) {
        if (msg.sender != operator) revert NotOperator();
        collection = Clones.clone(implementation);
        isCollection[collection] = true;
        collections.push(collection);
        JigsawCollection(collection).initialize(c, operator, phases, provenance, uri, revealLater, freeze);
        emit CollectionCreated(collection, c.creator, provenance, revealLater);
    }

    function collectionCount() external view returns (uint256) {
        return collections.length;
    }

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function setImplementation(address implementation_) external onlyOwner {
        if (implementation_.code.length == 0) revert NoCode(); // an EOA would register logic-less clones (internal round, 18 Oct)
        implementation = implementation_;
        emit ImplementationSet(implementation_);
    }
}
