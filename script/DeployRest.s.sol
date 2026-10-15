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
        require(block.chainid != 1, "no mainnet");
        uint256 pk = vm.envUint("LAUNCH_PK");
        address deployer = vm.addr(pk);
        address pot = vm.envAddress("POT");
        address platform = vm.envOr("PLATFORM", deployer);

        vm.startBroadcast(pk);
        AirdropClaim airdrop = new AirdropClaim(platform, pot);
        vm.stopBroadcast();

        console.log("chain            ", block.chainid);
        console.log("AirdropClaim     ", address(airdrop));
        console.log("reserve = pot    ", pot);
    }
}
