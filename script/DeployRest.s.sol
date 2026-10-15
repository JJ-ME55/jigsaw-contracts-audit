// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AirdropClaim} from "../src/AirdropClaim.sol";
import {CoinFactory} from "../src/CoinFactory.sol";
import {CreatorFeeHook} from "../src/CreatorFeeHook.sol";
import {LoomCollection} from "../src/nft/LoomCollection.sol";
import {LoomFactory} from "../src/nft/LoomFactory.sol";
import {ReferrerRegistry} from "../src/ReferrerRegistry.sol";

/// Step 2 of the Sepolia sequence (after DeployJIG): ReferrerRegistry (unless REGISTRY is given), AirdropClaim,
/// NFT v2 implementation + factory. Then DeployCoins with REGISTRY and AIRDROP, then DeployDeepening.
///
///   set -a; . ../backend/.env; set +a
///   POT=0x... forge script script/DeployRest.s.sol --rpc-url sepolia --broadcast --slow --skip-simulation
/// Reads LAUNCH_PK, POT, optional REGISTRY, optional PLATFORM (default deployer).
contract DeployRest is Script {
    function run() external {
        require(block.chainid != 1, "no mainnet");
        uint256 pk = vm.envUint("LAUNCH_PK");
        address deployer = vm.addr(pk);
        address pot = vm.envAddress("POT");
        address platform = vm.envOr("PLATFORM", deployer);
        address registry = vm.envOr("REGISTRY", address(0));

        vm.startBroadcast(pk);
        if (registry == address(0)) registry = address(new ReferrerRegistry(platform));
        AirdropClaim airdrop = new AirdropClaim(platform, pot);
        LoomCollection impl = new LoomCollection(platform, pot, registry);
        LoomFactory nftFactory = new LoomFactory(address(impl), platform, platform);
        vm.stopBroadcast();

        console.log("chain            ", block.chainid);
        console.log("Registry         ", registry);
        console.log("AirdropClaim     ", address(airdrop));
        console.log("LoomCollection v2", address(impl));
        console.log("LoomFactory v2   ", address(nftFactory));
        console.log("reserve = pot    ", pot);
    }
}
