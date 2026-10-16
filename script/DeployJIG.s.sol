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

/// CreateX, the universal deployer: same address on Sepolia, Ethereum and Robinhood Chain (checked 16 Oct 2026).
interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    function computeCreate3Address(bytes32 salt) external view returns (address computedAddress);
}

/// Phase 1 deploy: PotVault, JIGLaunch, JIG, Vesting, the launch hook, then the fair launch.
///
/// Sepolia, and Robinhood Chain (4663) on the written go only: Ethereum and Robinhood are refused unless
/// ALLOW_MAINNET_DEPLOY=1, and there POT_OWNER, PLATFORM, ALLOWLIST_ROOT and JIG_SALT are required (no defaults).
/// Run with LAUNCH_PK = the JIG deployer key (JIG_DEPLOYER_PK): its address is inside JIG_SALT.
///
/// Launch plan (agreed 15-16 Oct 2026, see README and docs/MAINNET-PLAN.md):
///   start price from START_TICK (default 202,400, about 1 ETH = 616M JIG, ~$4k FDV at ETH ~$2,460); set it from
///     the day's ETH price: JIG per ETH = 1.0001^START_TICK, a multiple of 200
///   seeded range: full range above the start price, single-sided JIG, no cap
///   first 5 minutes: allowlisted wallets pay 1.5%, everyone else 60%; then 1.5% for all; LP fees half team, half pot
///   if any transaction after JIG's CreateX deploy fails, do NOT rerun (the vanity address is taken): finish by hand
///     against the deployed JIGLaunch (docs/MAINNET-PLAN.md, "If the JIG deploy stops halfway")
///
/// Usage:
///   set -a; . ../backend/.env; set +a
///   ALLOWLIST_ROOT=0x... forge script script/DeployJIG.s.sol --rpc-url sepolia --broadcast --slow --skip-simulation
/// Reads LAUNCH_PK (deployer, launcher), optional POT_OWNER and ALLOWLIST_ROOT.
/// The hook is deployed with CREATE2 through forge's default deployer so its address carries the flag bits.
/// JIG_SALT (optional): deploy JIG through CreateX CREATE3 at a vanity address (Jj, 16 Oct: 0x000000...c011ec7).
/// The salt must start with the deployer's address and have 0x00 as byte 21 (permissioned, no cross-chain
/// protection), so only this deployer can use it and the address is the same on every chain. Its address depends
/// only on the salt, so it can be ground before these contracts are final: createxcrunch create3 --caller <deployer>
/// --crosschain 0 --matching 000000XXXXXXXXXXXXXXXXXXXXXXXXXXXc011ec7
contract DeployJIG is Script {
    int24 constant TICK_SPACING = 200;
    // The start tick: price = TickMath.getSqrtPriceAtTick(start), JIG per ETH = 1.0001^start. Default 202,400 is about
    // 616M JIG per ETH (~$4k FDV at ETH ~$2,460). On launch day set START_TICK from that day's ETH price (a multiple
    // of 200). The range top equals the start price, so the first buy is at the start price.
    int24 TICK_UPPER;
    uint160 SQRT_PRICE;
    int24 constant TICK_LOWER = -887_200; // full range below: no cap on price

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);

    function run() external {
        // Ethereum and Robinhood Chain are mainnets: refuse unless ALLOW_MAINNET_DEPLOY=1 is set on purpose (rule 1: both founders, in writing)
        if (block.chainid == 1 || block.chainid == 4663) require(vm.envOr("ALLOW_MAINNET_DEPLOY", false), "mainnet deploy refused: set ALLOW_MAINNET_DEPLOY=1 only after both founders said go in writing");
        (address posm, address permit2, address poolManager) = _v4(block.chainid);

        uint256 pk = vm.envUint("LAUNCH_PK"); // the JIG deployer (JIG_DEPLOYER_PK): its address is inside JIG_SALT
        address deployer = vm.addr(pk);
        bool mainnet = block.chainid == 1 || block.chainid == 4663;
        // On a mainnet every role is required: a silent default to the deployer would make a hot key the payee forever
        address potOwner = mainnet ? vm.envAddress("POT_OWNER") : vm.envOr("POT_OWNER", deployer); // the Safe
        address platform = mainnet ? vm.envAddress("PLATFORM") : vm.envOr("PLATFORM", deployer); // the Safe: team half of JIG pool fees
        bytes32 root = mainnet ? vm.envBytes32("ALLOWLIST_ROOT") : vm.envOr("ALLOWLIST_ROOT", bytes32(0));
        if (mainnet) require(root != bytes32(0), "ALLOWLIST_ROOT is required on a mainnet");
        if (mainnet) require(vm.envOr("JIG_SALT", bytes32(0)) != bytes32(0), "JIG_SALT is required on a mainnet (the vanity address)");
        TICK_UPPER = int24(vm.envOr("START_TICK", int256(202_400)));
        require(TICK_UPPER % TICK_SPACING == 0 && TICK_UPPER > 0, "START_TICK must be a positive multiple of 200");
        SQRT_PRICE = TickMath.getSqrtPriceAtTick(TICK_UPPER);

        vm.startBroadcast(pk);
        PotVault pot = new PotVault(potOwner);
        JIGLaunch launch = new JIGLaunch(posm, permit2, deployer, address(pot), platform);
        JIG jig = _deployJig(deployer, address(launch), address(pot));
        // Vesting is unused since creator vesting was dropped (15 Oct): not deployed on a mainnet
        Vesting vesting = mainnet ? Vesting(address(0)) : new Vesting();
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
    /// JIG at its vanity address through CreateX when JIG_SALT is set, else a plain CREATE (test deploys).
    function _deployJig(address deployer, address launch, address pot) internal returns (JIG jig) {
        bytes32 salt = vm.envOr("JIG_SALT", bytes32(0));
        if (salt == bytes32(0)) return new JIG(launch, pot);
        require(address(bytes20(salt)) == deployer && salt[20] == 0x00, "JIG_SALT must start with the deployer address and have byte 21 = 00");
        address expected = jigAddressFor(deployer, salt);
        jig = JIG(ICreateX(CREATEX).deployCreate3(salt, abi.encodePacked(type(JIG).creationCode, abi.encode(launch, pot))));
        require(address(jig) == expected, "JIG did not land at the ground address");
        console.log("JIG vanity  ", address(jig));
    }

    /// CreateX's permissioned, cross-chain-identical guard: keccak256(bytes32(deployer) ++ salt).
    function jigAddressFor(address deployer, bytes32 salt) public view returns (address) {
        return ICreateX(CREATEX).computeCreate3Address(keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), salt)));
    }

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
        if (chainId == 4663) {
            // Robinhood Chain, from developers.uniswap.org v4 deployments, checked on chain 16 Oct 2026 (all point at this PoolManager)
            return (0x58daec3116aae6D93017bAAea7749052E8a04fA7, 0x000000000022D473030F116dDEE9F6B43aC78BA3, 0x8366a39CC670B4001A1121B8F6A443A643e40951);
        }
        revert("v4 addresses not set for this chain");
    }
}
