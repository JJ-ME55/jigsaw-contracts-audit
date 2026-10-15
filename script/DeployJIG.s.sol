// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {JIG} from "../src/JIG.sol";
import {Vesting} from "../src/Vesting.sol";
import {PotVault} from "../src/PotVault.sol";
import {JIGLaunch} from "../src/JIGLaunch.sol";
import {JIGLaunchHook} from "../src/JIGLaunchHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// Phase 1 deploy: PotVault, JIGLaunch, JIG, Vesting, the launch hook, then the fair launch.
///
/// Sepolia only. ALLOW_MAINNET stays 0 in the back end and this script refuses
/// chain id 1. Robinhood Chain needs its v4 PositionManager/Permit2 addresses
/// filled in before it can run there.
///
/// Launch plan (agreed 15 Oct 2026, see README):
///   start price 1 ETH = 625,000,000 JIG (1B supply => 1.6 ETH fully diluted, ~$4k, a pump.fun-style start)
///   seeded range: full range above the start price, single-sided JIG, no cap
///   first 10 minutes: allowlisted wallets pay 1%, everyone else 60%, all to the pot; then 1% for all
///
/// Usage:
///   set -a; . ../backend/.env; set +a
///   ALLOWLIST_ROOT=0x... forge script script/DeployJIG.s.sol --rpc-url sepolia --broadcast --slow --skip-simulation
/// Reads LAUNCH_PK (deployer, launcher), optional POT_OWNER and ALLOWLIST_ROOT.
/// The hook is deployed with CREATE2 through forge's default deployer so its address carries the flag bits.
contract DeployJIG is Script {
    int24 constant TICK_SPACING = 200;
    int24 constant TICK_UPPER = 202_400; // the start tick: price = TickMath.getSqrtPriceAtTick(TICK_UPPER), about 1 ETH = 616M JIG, ~$4k FDV
    uint160 SQRT_PRICE = TickMath.getSqrtPriceAtTick(TICK_UPPER); // range top == start price, so the first buy is at the start price
    int24 constant TICK_LOWER = -887_200; // full range below: no cap on price

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    function run() external {
        require(block.chainid != 1, "no mainnet");
        (address posm, address permit2, address poolManager) = _v4(block.chainid);

        uint256 pk = vm.envUint("LAUNCH_PK");
        address deployer = vm.addr(pk);
        address potOwner = vm.envOr("POT_OWNER", deployer);
        bytes32 root = vm.envOr("ALLOWLIST_ROOT", bytes32(0));

        vm.startBroadcast(pk);
        PotVault pot = new PotVault(potOwner);
        JIGLaunch launch = new JIGLaunch(posm, permit2, deployer, address(pot));
        JIG jig = new JIG(address(launch), address(pot));
        Vesting vesting = new Vesting();
        launch.setJig(address(jig));

        bytes memory args = abi.encode(poolManager, address(jig), deployer, address(launch), SQRT_PRICE, TICK_SPACING);
        (address predicted, bytes32 salt) = _mine(type(JIGLaunchHook).creationCode, args);
        JIGLaunchHook hook = new JIGLaunchHook{salt: salt}(poolManager, address(jig), deployer, address(launch), SQRT_PRICE, TICK_SPACING);
        require(address(hook) == predicted, "hook address mismatch");
        if (root != bytes32(0)) hook.setAllowlist(root);

        uint256 tokenId = launch.launch(LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, address(hook), SQRT_PRICE, TICK_LOWER, TICK_UPPER);
        vm.stopBroadcast();

        console.log("chain       ", block.chainid);
        console.log("PotVault    ", address(pot));
        console.log("JIGLaunch   ", address(launch));
        console.log("JIG         ", address(jig));
        console.log("Vesting     ", address(vesting));
        console.log("LaunchHook  ", address(hook));
        console.log("LP tokenId  ", tokenId);
        console.log("window ends ", hook.windowEnd());
        console.log("pot owner   ", potOwner);
        console.log("allowlist   ", root == bytes32(0) ? "NONE: everyone pays 60% in the window" : "set");
    }

    /// Find a CREATE2 salt such that the hook lands on an address whose low 14 bits are exactly HOOK_FLAGS.
    function _mine(bytes memory creationCode, bytes memory args) internal view returns (address addr, bytes32 salt) {
        bytes32 initHash = keccak256(abi.encodePacked(creationCode, args));
        uint256 seed = vm.envOr("SALT_SEED", uint256(0));
        for (uint256 i = seed; i < seed + 200_000; i++) {
            salt = bytes32(i);
            addr = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initHash)))));
            if (uint160(addr) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) return (addr, salt);
        }
        revert("no salt found");
    }

    function _v4(uint256 chainId) internal pure returns (address posm, address permit2, address poolManager) {
        if (chainId == 11155111) {
            return (
                0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4,
                0x000000000022D473030F116dDEE9F6B43aC78BA3,
                0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
            );
        }
        revert("v4 addresses not set for this chain");
    }
}
