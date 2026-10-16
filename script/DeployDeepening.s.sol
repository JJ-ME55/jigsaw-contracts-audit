// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {LPDeepening} from "../src/LPDeepening.sol";
import {CreatorFeeHook} from "../src/CreatorFeeHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// Deploys LPDeepening against the live JIG/ETH pool and binds it to the fee hook (once).
///   set -a; . ../backend/.env; set +a
///   HOOK=0x... JIG=0x... JIG_POOL_HOOK=0x... forge script script/DeployDeepening.s.sol --rpc-url sepolia --broadcast --slow --skip-simulation
/// JIG_POOL_HOOK is the JIGLaunchHook address (the pool is dynamic-fee, tick spacing 200). Reads LAUNCH_PK (must be the hook owner).
contract DeployDeepening is Script {
    function run() external {
        // Ethereum and Robinhood Chain are mainnets: refuse unless ALLOW_MAINNET_DEPLOY=1 is set on purpose (rule 1: both founders, in writing)
        if (block.chainid == 1 || block.chainid == 4663) require(vm.envOr("ALLOW_MAINNET_DEPLOY", false), "mainnet deploy refused: set ALLOW_MAINNET_DEPLOY=1 only after both founders said go in writing");
        (address posm, address permit2) = _v4(block.chainid);
        uint256 pk = vm.envUint("LAUNCH_PK");
        address hook = vm.envAddress("HOOK");
        address jig = vm.envAddress("JIG");
        address jigPoolHook = vm.envAddress("JIG_POOL_HOOK");

        PoolKey memory jigPool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(jig),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(jigPoolHook)
        });

        vm.startBroadcast(pk);
        // KEEPER runs run(minEthOut): the operating wallet. Immutable, so required on a mainnet.
        address keeper = (block.chainid == 1 || block.chainid == 4663) ? vm.envAddress("KEEPER") : vm.envOr("KEEPER", vm.addr(pk));
        LPDeepening deep = new LPDeepening(hook, posm, permit2, jigPool, keeper);
        CreatorFeeHook(hook).setDeepening(address(deep));
        vm.stopBroadcast();

        console.log("chain        ", block.chainid);
        console.log("LPDeepening  ", address(deep));
        console.log("hook.deepening", CreatorFeeHook(hook).deepening());
    }

    function _v4(uint256 chainId) internal pure returns (address posm, address permit2) {
        if (chainId == 11155111) return (0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4, 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        if (chainId == 4663) {
            // Robinhood Chain, from developers.uniswap.org v4 deployments, checked on chain 16 Oct 2026 (all point at this PoolManager)
            return (0x58daec3116aae6D93017bAAea7749052E8a04fA7, 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        }
        revert("v4 addresses not set for this chain");
    }
}
