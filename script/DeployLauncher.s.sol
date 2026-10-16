// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {CollectionLauncher} from "../src/CollectionLauncher.sol";

/// Deploys CollectionLauncher for the chain's Loom NFT factory. The back end creates every collection through it
/// (provenance and first URI in the creating transaction), and refuses mainnet launches without one.
///   set -a; . ../backend/.env; set +a
///   NFT_FACTORY=0x... OPERATOR=0x... forge script script/DeployLauncher.s.sol --rpc-url sepolia --broadcast --slow --skip-simulation
/// NFT_FACTORY: the Loom factory. OPERATOR: the operating wallet (it calls create() and accepts each collection's
/// ownership). Both are required. Set the result as SEPOLIA_LAUNCHER / RH_LAUNCHER on the server.
contract DeployLauncher is Script {
    function run() external {
        // Ethereum and Robinhood Chain are mainnets: refuse unless ALLOW_MAINNET_DEPLOY=1 is set on purpose (rule 1: both founders, in writing)
        if (block.chainid == 1 || block.chainid == 4663) require(vm.envOr("ALLOW_MAINNET_DEPLOY", false), "mainnet deploy refused: set ALLOW_MAINNET_DEPLOY=1 only after both founders said go in writing");
        uint256 pk = vm.envUint("LAUNCH_PK");
        address factory = vm.envAddress("NFT_FACTORY");
        address operator = vm.envAddress("OPERATOR");
        require(factory.code.length > 0, "NFT_FACTORY has no code on this chain");
        vm.startBroadcast(pk);
        CollectionLauncher launcher = new CollectionLauncher(factory, operator);
        vm.stopBroadcast();
        console.log("CollectionLauncher", address(launcher));
        console.log("  factory ", factory);
        console.log("  operator", operator);
    }
}
