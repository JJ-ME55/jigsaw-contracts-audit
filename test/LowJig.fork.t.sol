// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JIG} from "../src/JIG.sol";
import {FlywheelsForkTest} from "./Flywheels.fork.t.sol";
import {RegressionsForkTest} from "./Regressions.fork.t.sol";

// The real JIG lands at 0x00000...c011ec7 (CreateX vanity, Jj 16 Oct), below every coin address, so in every coin pool
// the coin is currency1 and JIG currency0. These rerun the whole flywheel and fee-hook regression suites with JIG at a
// very low address, so that ordering is exercised end to end (pre-audit review, 16 Oct).
address constant LOW_JIG = 0x00000000000000000000000000000000000C011E;

contract LowJigFlywheelsForkTest is FlywheelsForkTest {
    function _deployJig(address l, address p) internal override returns (JIG) {
        deployCodeTo("JIG.sol:JIG", abi.encode(l, p), LOW_JIG);
        return JIG(LOW_JIG);
    }
}

contract LowJigRegressionsForkTest is RegressionsForkTest {
    function _deployJig(address l, address p) internal override returns (JIG) {
        deployCodeTo("JIG.sol:JIG", abi.encode(l, p), LOW_JIG);
        return JIG(LOW_JIG);
    }

    function test_every_coin_sorts_above_a_low_jig() public {
        (, , bool coinIs0) = _launchCoin(creator, address(0));
        assertFalse(coinIs0, "with JIG at a low address the coin is always currency1");
    }
}
