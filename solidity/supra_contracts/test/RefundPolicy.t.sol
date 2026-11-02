// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";

/// Guards the two places that name every value of an enum the refund depends on
/// (Entropy-Foundation/smr-moonshot#4652): `LibCore.handleTasksRemoval`, which gives each
/// `TaskRemovalReason` its admission check, refund policy and event, and
/// `LibAccounting.unlockDepositAndCycleFee`, which gives each `RefundPolicy` its divisor. Both
/// revert on a value they do not name, a path no current value reaches, so these tests fail
/// first, when the enum grows, and say where the new value needs handling.
///
/// The refund each reason pays is pinned end to end per removal path, by the stop,
/// governance-removal and config-update-removal tests, among them
/// `ConfigUpdateRemovalTest.testErrorAndConfigUpdateRemovalsRefundDifferently`.
contract RefundPolicyTest is Test {
    function testEveryRemovalReasonIsHandled() public pure {
        assertEq(
            uint8(type(LibCommon.TaskRemovalReason).max),
            uint8(LibCommon.TaskRemovalReason.CONFIG_UPDATE),
            "a TaskRemovalReason was added: give it its handling in LibCore.handleTasksRemoval"
        );
    }

    function testEveryRefundPolicyHasADivisor() public pure {
        assertEq(
            uint8(type(LibCommon.RefundPolicy).max),
            uint8(LibCommon.RefundPolicy.FULL),
            "a RefundPolicy was added: give it its divisor in LibAccounting.unlockDepositAndCycleFee"
        );
    }
}
