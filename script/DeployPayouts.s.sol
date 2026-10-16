// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {HolderPayouts} from "../src/HolderPayouts.sol";

/// Deploys the shared HolderPayouts (snapshot rounds for "fees to coin holders" flywheels).
///   set -a; . ../backend/.env; set +a
///   JIG=0x... forge script script/DeployPayouts.s.sol --rpc-url sepolia --broadcast --slow --skip-simulation
/// Reads LAUNCH_PK, JIG, PAYOUTS_OWNER (the owner who declares rounds; required on a mainnet, default deployer elsewhere).
contract DeployPayouts is Script {
    function run() external {
        // Ethereum and Robinhood Chain are mainnets: refuse unless ALLOW_MAINNET_DEPLOY=1 is set on purpose (rule 1: both founders, in writing)
        if (block.chainid == 1 || block.chainid == 4663) require(vm.envOr("ALLOW_MAINNET_DEPLOY", false), "mainnet deploy refused: set ALLOW_MAINNET_DEPLOY=1 only after both founders said go in writing");
        uint256 pk = vm.envUint("LAUNCH_PK");
        // PAYOUTS_OWNER writes the round roots: the operating wallet. It holds no funds directly, but a root it declares
        // decides who can claim (see README, "Known risks"). Required on a mainnet.
        address platform = (block.chainid == 1 || block.chainid == 4663) ? vm.envAddress("PAYOUTS_OWNER") : vm.envOr("PAYOUTS_OWNER", vm.addr(pk));
        address jig = vm.envAddress("JIG");
        vm.startBroadcast(pk);
        HolderPayouts p = new HolderPayouts(platform, jig);
        vm.stopBroadcast();
        console.log("chain         ", block.chainid);
        console.log("HolderPayouts ", address(p));
    }
}
