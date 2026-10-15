// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {JIG} from "../src/JIG.sol";
import {Vesting} from "../src/Vesting.sol";
import {PotVault} from "../src/PotVault.sol";
import {JIGLaunch} from "../src/JIGLaunch.sol";

/// Phase 1 deploy: PotVault, JIGLaunch, JIG, Vesting, then the fair launch.
///
/// Sepolia only. ALLOW_MAINNET stays 0 in the back end and this script refuses
/// chain id 1. Robinhood Chain needs its v4 PositionManager/Permit2 addresses
/// filled in before it can run there.
///
/// Launch parameters (to be confirmed by both founders before mainnet):
///   fee 1%, tick spacing 200
///   start price 1 ETH = 5,000,000 JIG  (1B supply => 200 ETH fully diluted, ~$500k)
///   seeded range: from the start price up to ~1000x, single-sided JIG
///
/// Usage:
///   set -a; . ../backend/.env; set +a
///   forge script script/DeployJIG.s.sol --rpc-url sepolia --broadcast
/// Reads LAUNCH_PK (deployer, launcher) and optionally POT_OWNER.
contract DeployJIG is Script {
    uint24 constant FEE = 10_000;
    int24 constant TICK_SPACING = 200;
    uint160 constant SQRT_PRICE = 177159557114295716651832025546752; // sqrt(5e6) * 2^96
    int24 constant TICK_UPPER = 154_200;
    int24 constant TICK_LOWER = 85_200;

    function run() external {
        require(block.chainid != 1, "no mainnet");
        (address posm, address permit2) = _v4(block.chainid);

        uint256 pk = vm.envUint("LAUNCH_PK");
        address deployer = vm.addr(pk);
        address potOwner = vm.envOr("POT_OWNER", deployer);

        vm.startBroadcast(pk);
        PotVault pot = new PotVault(potOwner);
        JIGLaunch launch = new JIGLaunch(posm, permit2, deployer, address(pot));
        JIG jig = new JIG(address(launch), address(pot));
        Vesting vesting = new Vesting();
        launch.setJig(address(jig));
        uint256 tokenId = launch.launch(FEE, TICK_SPACING, address(0), SQRT_PRICE, TICK_LOWER, TICK_UPPER);
        vm.stopBroadcast();

        console.log("chain      ", block.chainid);
        console.log("PotVault   ", address(pot));
        console.log("JIGLaunch  ", address(launch));
        console.log("JIG        ", address(jig));
        console.log("Vesting    ", address(vesting));
        console.log("LP tokenId ", tokenId);
        console.log("pot owner  ", potOwner);
    }

    function _v4(uint256 chainId) internal pure returns (address posm, address permit2) {
        if (chainId == 11155111) {
            return (0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4, 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        }
        revert("v4 addresses not set for this chain");
    }
}
