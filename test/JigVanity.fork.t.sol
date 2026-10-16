// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JIG} from "../src/JIG.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    function computeCreate3Address(bytes32 salt) external view returns (address computedAddress);
}

/// JIG at a vanity address through CreateX CREATE3 (Jj, 16 Oct). forge test --match-contract JigVanity --fork-url sepolia
contract JigVanityForkTest is Test {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    address deployer = makeAddr("jigDeployer");
    address stranger = makeAddr("stranger");
    address launch = makeAddr("launch");
    address pot = makeAddr("pot");

    function setUp() public { vm.createSelectFork("sepolia"); }

    function _guarded(address who, bytes32 salt) internal pure returns (bytes32) { return keccak256(abi.encodePacked(bytes32(uint256(uint160(who))), salt)); }

    function test_jig_lands_at_the_address_computed_from_the_salt_alone() public {
        bytes32 salt = bytes32(bytes20(deployer)) | bytes32(uint256(0xC011EC7)); // byte 21 = 00: same address on every chain
        address expected = CREATEX.computeCreate3Address(_guarded(deployer, salt));
        vm.prank(deployer);
        address jig = CREATEX.deployCreate3(salt, abi.encodePacked(type(JIG).creationCode, abi.encode(launch, pot)));
        assertEq(jig, expected, "the ground address");
        assertEq(JIG(jig).balanceOf(launch), 900_000_000e18);
        assertEq(JIG(jig).balanceOf(pot), 100_000_000e18);
        assertEq(JIG(jig).symbol(), "JIG");
    }

    function test_the_address_does_not_depend_on_the_code_so_the_grind_can_start_early() public {
        bytes32 salt = bytes32(bytes20(deployer)) | bytes32(uint256(7));
        address expected = CREATEX.computeCreate3Address(_guarded(deployer, salt));
        vm.prank(deployer);
        address jig = CREATEX.deployCreate3(salt, abi.encodePacked(type(JIG).creationCode, abi.encode(makeAddr("other launch"), makeAddr("other pot"))));
        assertEq(jig, expected, "different constructor args, same address");
    }

    function test_a_stranger_with_our_salt_lands_somewhere_else() public {
        bytes32 salt = bytes32(bytes20(deployer)) | bytes32(uint256(0xC011EC7));
        address ours = CREATEX.computeCreate3Address(_guarded(deployer, salt));
        vm.prank(stranger);
        address theirs = CREATEX.deployCreate3(salt, abi.encodePacked(type(JIG).creationCode, abi.encode(launch, pot)));
        assertTrue(theirs != ours, "a copied salt cannot take our address");
        assertEq(ours.code.length, 0, "ours is still free");
        vm.prank(deployer);
        assertEq(CREATEX.deployCreate3(salt, abi.encodePacked(type(JIG).creationCode, abi.encode(launch, pot))), ours);
    }
}
