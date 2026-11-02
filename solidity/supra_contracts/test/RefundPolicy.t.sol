// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";

/// Pins the mapping from a runtime removal reason to the refund policy it applies
/// (Entropy-Foundation/smr-moonshot#4652). The refund amounts each policy pays are pinned per
/// removal path by the stop, governance-removal and config-update-removal tests; this file pins
/// only which policy each reason selects.
contract RefundPolicyTest is Test {
    /// An ERROR removal refunds like a stop: the task failed, so its owner bears half the
    /// remaining cycle fee.
    function testAnErrorRemovalAppliesThePartialRefund() public pure {
        assertEq(
            uint8(LibCommon.refundPolicyOf(LibCommon.TaskRemovalReason.ERROR)),
            uint8(LibCommon.RefundPolicy.PARTIAL)
        );
    }

    /// A CONFIG_UPDATE removal refunds in full: governance changed a figure the task depended on,
    /// so the owner bears nothing (#4087).
    function testAConfigUpdateRemovalAppliesTheFullRefund() public pure {
        assertEq(
            uint8(LibCommon.refundPolicyOf(LibCommon.TaskRemovalReason.CONFIG_UPDATE)),
            uint8(LibCommon.RefundPolicy.FULL)
        );
    }

    /// Fails when a removal reason is added, so that whoever adds one decides its refund policy in
    /// `LibCommon.refundPolicyOf` and adds its case above, rather than inheriting PARTIAL from the
    /// mapping's fallback branch unexamined.
    function testEveryRemovalReasonHasAPinnedPolicy() public pure {
        assertEq(
            uint8(type(LibCommon.TaskRemovalReason).max),
            uint8(LibCommon.TaskRemovalReason.CONFIG_UPDATE),
            "a TaskRemovalReason was added: give it a refund policy and a test case above"
        );
    }

    /// The registry pays exactly two refund shares. A third policy would need its own divisor in
    /// `LibAccounting.unlockDepositAndCycleFee`, which maps every policy other than FULL to the
    /// partial divisor.
    function testThereAreExactlyTwoRefundPolicies() public pure {
        assertEq(
            uint8(type(LibCommon.RefundPolicy).max),
            uint8(LibCommon.RefundPolicy.FULL),
            "a RefundPolicy was added: map it to its divisor in unlockDepositAndCycleFee"
        );
    }
}
