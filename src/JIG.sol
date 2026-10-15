// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title JIG, the Jigsaw platform token
/// @notice Fixed supply, minted once in the constructor, split 90% to the launch
///         contract and 10% to the pot vault. No mint function, no tax, no owner.
///         Burnable so JIG paid for builds can be partly destroyed (spec 3d).
contract JIG is ERC20, ERC20Permit, ERC20Burnable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant LAUNCH_SHARE = 900_000_000e18; // 90%
    uint256 public constant POT_SHARE = 100_000_000e18; // 10%

    error ZeroAddress();

    constructor(address launch, address potVault) ERC20("JIG", "JIG") ERC20Permit("JIG") {
        if (launch == address(0) || potVault == address(0)) revert ZeroAddress();
        _mint(launch, LAUNCH_SHARE);
        _mint(potVault, POT_SHARE);
    }
}
