// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AirdropClaim} from "../src/AirdropClaim.sol";
import {CoinFactory} from "../src/CoinFactory.sol";
import {CreatorFeeHook} from "../src/CreatorFeeHook.sol";

/// Step 2 of the Sepolia sequence (after DeployJIG): AirdropClaim. Then DeployCoins with AIRDROP, then DeployDeepening.
///
///   set -a; . ../backend/.env; set +a
///   POT=0x... forge script script/DeployRest.s.sol --rpc-url sepolia --broadcast --slow --skip-simulation
/// Reads LAUNCH_PK, POT, optional PLATFORM (default deployer).
contract DeployRest is Script {
    function run() external {
        // Ethereum and Robinhood Chain are mainnets: refuse unless ALLOW_MAINNET_DEPLOY=1 is set on purpose (rule 1: both founders, in writing)
        if (block.chainid == 1 || block.chainid == 4663) require(vm.envOr("ALLOW_MAINNET_DEPLOY", false), "mainnet deploy refused: set ALLOW_MAINNET_DEPLOY=1 only after both founders said go in writing");
        uint256 pk = vm.envUint("LAUNCH_PK");
        address deployer = vm.addr(pk);
        address pot = vm.envAddress("POT");
        // Owned by the deployer only until DeployCoins (same key) calls setFactory, then renounced: the per-NFT airdrop
        // has no owner powers (17 Oct).
        vm.startBroadcast(pk);
        AirdropClaim airdrop = new AirdropClaim(deployer, pot);
        vm.stopBroadcast();

        console.log("chain            ", block.chainid);
        console.log("AirdropClaim     ", address(airdrop));
        console.log("reserve = pot    ", pot);
    }
}
