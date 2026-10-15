// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {CreatorFeeHook} from "../src/CreatorFeeHook.sol";
import {CoinFactory} from "../src/CoinFactory.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// Phase 2 deploy: the shared CreatorFeeHook and the CoinFactory, bound to an existing JIG set.
///
/// Sepolia only. Reads LAUNCH_PK (deployer = hook owner), JIG, POT, VESTING, optional PLATFORM
/// (default deployer), DEEPENING (default POT), AIRDROP (default POT), LAUNCH_FEE_WEI (default 0.01 ether).
///
///   set -a; . ../backend/.env; set +a
///   JIG=0x... POT=0x... VESTING=0x... forge script script/DeployCoins.s.sol --rpc-url sepolia --broadcast --slow --skip-simulation
contract DeployCoins is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    function run() external {
        require(block.chainid != 1, "no mainnet");
        (address posm, address permit2, address poolManager) = _v4(block.chainid);

        uint256 pk = vm.envUint("LAUNCH_PK");
        address deployer = vm.addr(pk);
        address jig = vm.envAddress("JIG");
        address pot = vm.envAddress("POT");
        address vesting = vm.envAddress("VESTING");
        address platform = vm.envOr("PLATFORM", deployer);
        address deepening = vm.envOr("DEEPENING", pot);
        address airdrop = vm.envOr("AIRDROP", pot);
        uint256 launchFee = vm.envOr("LAUNCH_FEE_WEI", uint256(0.01 ether));

        bytes memory args = abi.encode(poolManager, jig, deployer, platform, pot, deepening);
        (address predicted, bytes32 salt) = _mine(type(CreatorFeeHook).creationCode, args);

        vm.startBroadcast(pk);
        CreatorFeeHook hook = new CreatorFeeHook{salt: salt}(poolManager, jig, deployer, platform, pot, deepening);
        require(address(hook) == predicted, "hook address mismatch");
        CoinFactory factory = new CoinFactory(posm, permit2, address(hook), vesting, jig, platform, airdrop, launchFee);
        hook.setFactory(address(factory));
        vm.stopBroadcast();

        console.log("chain          ", block.chainid);
        console.log("CreatorFeeHook ", address(hook));
        console.log("CoinFactory    ", address(factory));
        console.log("platform       ", platform);
        console.log("launch fee wei ", launchFee);
    }

    function _mine(bytes memory creationCode, bytes memory args) internal pure returns (address addr, bytes32 salt) {
        bytes32 initHash = keccak256(abi.encodePacked(creationCode, args));
        for (uint256 i; i < 300_000; i++) {
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
