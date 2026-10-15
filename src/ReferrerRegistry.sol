// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title ReferrerRegistry
/// @notice The platform's list of approved referral recipients (front ends that embed the
///         mint or coin widgets). Used by CreatorFeeHook (trade referral) and LoomCollection
///         v2 (mint referral). An address that is not approved is treated as no referral and
///         the slice stays with the platform, so swappers and minters cannot rebate themselves.
contract ReferrerRegistry is Ownable2Step {
    mapping(address => bool) public isReferrer;

    event ReferrerSet(address indexed referrer, bool approved);

    constructor(address owner_) Ownable(owner_) {}

    function setReferrer(address referrer, bool approved) external onlyOwner {
        isReferrer[referrer] = approved;
        emit ReferrerSet(referrer, approved);
    }
}

interface IReferrerRegistry {
    function isReferrer(address) external view returns (bool);
}
