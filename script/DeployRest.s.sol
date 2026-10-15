// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AirdropClaim} from "../src/AirdropClaim.sol";
import {CoinFactory} from "../src/CoinFactory.sol";
import {CreatorFeeHook} from "../src/CreatorFeeHook.sol";
import {LoomCollection} from "../src/nft/LoomCollection.sol";
import {LoomFactory} from "../src/nft/LoomFactory.sol";

/// Deploys AirdropClaim, a CoinFactory bound to it (the hook's factory binding is one-shot, so this
/// also deploys a fresh CreatorFeeHook... no: the hook is CREATE2-mined in DeployCoins. Run DeployCoins
/// with AIRDROP=<AirdropClaim> instead for a hook+factory pair. This script deploys the pieces that
/// don't need address mining: AirdropClaim and the NFT v2 implementation + factory.
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
        LoomCollection impl = new LoomCollection(platform, pot);
        LoomFactory nftFactory = new LoomFactory(address(impl), platform, platform);
        vm.stopBroadcast();

        console.log("chain            ", block.chainid);
        console.log("AirdropClaim     ", address(airdrop));
        console.log("LoomCollection v2", address(impl));
        console.log("LoomFactory v2   ", address(nftFactory));
        console.log("reserve = pot    ", pot);
    }
}
