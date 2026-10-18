// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {JigsawCollection} from "../src/JigsawCollection.sol";
import {JigsawCollectionFactory} from "../src/JigsawCollectionFactory.sol";

/// Deploys the JigsawCollection implementation (phased mints: VIP / allowlist / public) and its factory.
///   set -a; . ../backend/.env; set +a
///   PLATFORM=0x... RESERVE=0x... OPERATOR=0x... ADMIN=0x... forge script script/DeployPhased.s.sol --rpc-url sepolia --broadcast --slow --skip-simulation
/// PLATFORM / RESERVE: where the 0.0005 ETH per-mint fee's 40% and 20% go (the Loom collections use the operating
/// wallet for both). OPERATOR: the operating wallet (creates and owns every collection). ADMIN: the Safe (may change the
/// operator and the implementation). Set the factory as SEPOLIA_PHASED_FACTORY / RH_PHASED_FACTORY on the server.
contract DeployPhased is Script {
    function run() external {
        if (block.chainid == 1 || block.chainid == 4663) require(vm.envOr("ALLOW_MAINNET_DEPLOY", false), "mainnet deploy refused: set ALLOW_MAINNET_DEPLOY=1 only after both founders said go in writing");
        uint256 pk = vm.envUint("LAUNCH_PK");
        address platform = vm.envAddress("PLATFORM");
        address reserve = vm.envAddress("RESERVE");
        address operator = vm.envAddress("OPERATOR");
        address admin = vm.envAddress("ADMIN");
        vm.startBroadcast(pk);
        JigsawCollection impl = new JigsawCollection(platform, reserve);
        JigsawCollectionFactory factory = new JigsawCollectionFactory(address(impl), operator, admin);
        vm.stopBroadcast();
        console.log("JigsawCollection impl  ", address(impl));
        console.log("JigsawCollectionFactory", address(factory));
    }
}
