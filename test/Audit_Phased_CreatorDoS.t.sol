// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PhasedAuditBase} from "./Audit_Phased_Base.sol";
import {JigsawCollection} from "../src/JigsawCollection.sol";

contract RejectingCreator {} // no receive / fallback

contract GasBurningCreator {
    receive() external payable {
        uint256 i;
        while (gasleft() > 30_000) i++;
    }
}

contract Audit_Phased_CreatorDoS is PhasedAuditBase {
    function _ps() internal pure returns (JigsawCollection.Phase[] memory ps) {
        ps = new JigsawCollection.Phase[](1);
        ps[0] = JigsawCollection.Phase({start: T0, price: 0, maxPerWallet: 5, supply: 0, root: bytes32(0)});
    }

    /// A creator that cannot take ETH bricks every mint path (creator has no setter); the owner cannot repair it.
    function test_creatorRejectingEthBricksMint() public {
        _deploy();
        RejectingCreator rc = new RejectingCreator();
        JigsawCollection col = _create(_cfg(address(rc), 1000, 5), _ps(), true, false, "ipfs://p");
        vm.warp(T0);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(JigsawCollection.ETHTransferFailed.selector, address(rc)));
        col.mint{value: FEE}(1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(JigsawCollection.ETHTransferFailed.selector, address(rc)));
        col.reserveMint{value: FEE}(1);
        assertEq(col.totalSupply(), 0);
    }

    /// A creator contract can make each mint burn nearly the whole gas limit (the push forwards all gas).
    function test_creatorGasGriefsMinters() public {
        _deploy();
        GasBurningCreator gc = new GasBurningCreator();
        JigsawCollection col = _create(_cfg(address(gc), 1000, 5), _ps(), true, false, "ipfs://p");
        vm.warp(T0);
        vm.prank(minter);
        uint256 g = gasleft();
        col.mint{value: FEE, gas: 3_000_000}(1);
        uint256 used = g - gasleft();
        emit log_named_uint("gas used by a 1-token mint", used);
        assertGt(used, 2_000_000);
    }
}
