// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title CreatorCoin
/// @notice A creator coin attached to one NFT collection. Fixed supply minted once to
///         the factory, which distributes it. No mint, no tax, no owner. Burnable so the
///         buyback-and-burn flywheel can destroy it.
contract CreatorCoin is ERC20, ERC20Permit, ERC20Burnable {
    address public immutable collection;

    constructor(string memory name_, string memory symbol_, uint256 supply, address collection_, address to)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        collection = collection_;
        _mint(to, supply);
    }
}
