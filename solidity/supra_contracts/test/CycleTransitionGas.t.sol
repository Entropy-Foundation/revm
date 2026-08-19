// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {Deployment, InitParams, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";

/// @notice Gas benchmark for the automation-registry's three cycle-transition flows,
///         by default at the production task-registry cap (200 tasks: 160 UST + 40
///         GST, matching LibDiamondUtils.defaultInitParams()), submitted as batches
///         of 25 tasks (the assumed VM_SIGNER batch size - not an on-chain constant).
///
///         UST/GST task counts are overridable via env vars for one-off custom-N
///         runs, without touching this file - see
///         AUTOMATION_REGISTRY_GAS_GUIDE.md's "Running with a custom task count"
///         section:
///           CYCLE_GAS_BENCH_UST_COUNT           (default 160)
///           CYCLE_GAS_BENCH_GST_COUNT           (default 40)
///           CYCLE_GAS_BENCH_EXPIRING_UST_COUNT  (default 20, scenario 3 only)
///
///   1. FINISHED -> STARTED, everything survives (testCycleTransitionGas_FullFlow_ProductionMix)
///   2. STARTED (mid-cycle) -> SUSPENDED -> READY, everything is dropped/refunded
///      (testCycleTransitionGas_MidCycle_StartedToSuspended_FullRegistry)
///   3. FINISHED -> STARTED with a subset of tasks expiring mid-transition
///      (testCycleTransitionGas_FullFlow_SecondCycle_WithExpiredTasks)
///
/// `MonitorCycleEndGas.t.sol` only measures `monitorCycleEnd`. The order-independent
/// task-list compaction work (see Issue-3445) introduced costs that actually land in
/// `processTasks`, not `monitorCycleEnd`:
///   - Every surviving task pushes onto `transitionState.survivedTaskIds`
///     (LibCore.sol, dropOrChargeTasks) - a fresh-slot SSTORE per task, repeated in
///     whichever batch it falls into.
///   - The batch that finalizes the transition additionally pays
///     `updateRegistryState`'s two O(n) array assignments (`activeTaskIds`/
///     `orderedTaskIds`) plus `moveToStartedState`'s `delete` of the whole transition
///     struct - costs proportional to the total task count, landed entirely on that
///     one terminal call, regardless of which of the three flows above it belongs to.
///
/// Every measurement is logged so `forge test --match-contract CycleTransitionGasTest
/// -vv` gives a ready-to-read reference, the same way MonitorCycleEndGas.t.sol does.
/// The summary across all three scenarios is written up as a downstream-facing
/// reference in crates/supra-extension/src/AUTOMATION_REGISTRY_GAS_GUIDE.md.
contract CycleTransitionGasTest is BaseDiamondTest {

    /// @dev Default UST/GST counts when CYCLE_GAS_BENCH_UST_COUNT/
    ///      CYCLE_GAS_BENCH_GST_COUNT are unset: taskCapacity=160 + sysTaskCapacity=40
    ///      = 200, matching MAX_SUPPORTED_AUTOMATION_TASKS (crates/supra-extension)
    ///      and LibDiamondUtils.defaultInitParams(). Read via _ustTaskCount()/
    ///      _gstTaskCount() rather than directly, everywhere except _deployRegistry's
    ///      "does this custom count still fit the production capacity" comparison.
    uint256 constant TOTAL_UST = 160;
    uint256 constant TOTAL_GST = 40;

    /// @dev Assumed per-processTasks-call batch size. Not an on-chain constant -
    ///      no such cap exists in the contract or in crates/supra-extension; this is
    ///      the off-chain VM_SIGNER submitter's convention being characterized here.
    ///      Not overridable - only the task counts are, per the class's NatSpec.
    uint256 constant BATCH_SIZE = 25;

    /// @dev Generic single-tx sanity ceiling, matching the pattern already used in
    ///      CoreFacet.t.sol's testStopTasksBulkRemovalFromActiveTaskIdsStaysWithinGasBudget.
    ///      This is NOT the authoritative node-assigned processTasks record gas limit -
    ///      that calibration lives outside this repo. Confirming real headroom means
    ///      comparing the logged final-batch figure against whatever gas_limit the
    ///      node actually assigns to a processTasks record.
    uint256 constant SANITY_GAS_CEILING = 30_000_000;

    // ────────────────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Reads CYCLE_GAS_BENCH_UST_COUNT, falling back to the production default
    ///      (TOTAL_UST=160) when unset.
    function _ustTaskCount() internal view returns (uint256) {
        return vm.envOr("CYCLE_GAS_BENCH_UST_COUNT", TOTAL_UST);
    }

    /// @dev Reads CYCLE_GAS_BENCH_GST_COUNT, falling back to the production default
    ///      (TOTAL_GST=40) when unset.
    function _gstTaskCount() internal view returns (uint256) {
        return vm.envOr("CYCLE_GAS_BENCH_GST_COUNT", TOTAL_GST);
    }

    /// @dev Reads CYCLE_GAS_BENCH_EXPIRING_UST_COUNT, falling back to the default
    ///      (EXPIRING_UST_COUNT=20) when unset. Scenario 3 only.
    function _expiringUstTaskCount() internal view returns (uint256) {
        return vm.envOr("CYCLE_GAS_BENCH_EXPIRING_UST_COUNT", EXPIRING_UST_COUNT);
    }

    /// @dev Deploys a diamond sized for `_ustCount` UST + `_gstCount` GST tasks.
    ///      When both counts fit the production defaults (LibDiamondUtils.
    ///      defaultInitParams' taskCapacity=160/sysTaskCapacity=40), InitParams are
    ///      left completely unmodified, so the default (no env vars set) run is
    ///      byte-for-byte the same deployment as before this was made configurable.
    ///      A count exceeding its production default widens that capacity - and its
    ///      paired gas cap, so registration isn't gated by it - to fit, following the
    ///      same `n * 100_000 + 1_000_000` sizing MonitorCycleEndGas.t.sol uses.
    ///      Also authorizes `bob` to submit GST tasks.
    function _deployRegistry(uint256 _ustCount, uint256 _gstCount) internal returns (address diamond) {
        InitParams memory p = LibDiamondUtils.defaultInitParams();

        if (_ustCount > p.taskCapacity) {
            p.taskCapacity = uint16(_ustCount);
            p.registryMaxGasCap = uint128(_ustCount * 100_000 + 1_000_000);
        }
        if (_gstCount > p.sysTaskCapacity) {
            p.sysTaskCapacity = uint16(_gstCount);
            p.sysRegistryMaxGasCap = uint128(_gstCount * 100_000 + 1_000_000);
        }

        vm.startPrank(admin);
        Deployment memory d = LibDiamondUtils.deploy(admin, address(erc20Supra), p);
        diamond = d.diamond;
        IConfigFacet(diamond).grantAuthorization(bob);
        vm.stopPrank();
    }

    /// @dev Registers `_n` UST tasks on `_diamond` with an explicit `_expiry`,
    ///      bulk-funding alice once upfront. Unlike MonitorCycleEndGas.t.sol's
    ///      registration helper (which only measures monitorCycleEnd and never runs
    ///      processTasks), this benchmark also drives every task through
    ///      dropOrChargeTask -> tryWithdrawTaskAutomationFee, which pulls an
    ///      *additional* per-cycle automation fee from alice on top of the 61.1
    ///      ether/task locked at registration (flatRegistrationFeeWei 1 ether +
    ///      automationFeeCapForCycle 60.1 ether). At production defaults that fee is
    ///      ~3 ether/task (automationBaseFeeWeiPerSec 0.5 ether/sec * cycleDurationSecs
    ///      1200s * maxGasAmount 100_000 / registryMaxGasCap 20_000_000). 200 ether/task
    ///      leaves a large margin over the ~64.1 ether/task actually required.
    /// @param _expiry Absolute expiry timestamp. Must be strictly greater than the
    ///      current cycle's end time (LibRegistry.validateTaskDuration enforces this
    ///      at registration) - callers that want a task to expire mid-registry-lifetime
    ///      must register it with an expiry inside a *later* cycle, then let time pass.
    function _registerUstTasks(address _diamond, uint256 _n, uint64 _expiry) internal {
        uint256 depositAmount = _n * 200 ether;
        vm.deal(alice, depositAmount + 100 ether);

        bytes[] memory auxData;
        bytes memory payload = createPayload(
            0,
            address(erc20SupraHandler),
            abi.encodeCall(erc20SupraHandler.withdraw, 100)
        );
        bytes memory predicate = createPredicate(_diamond);

        vm.startPrank(alice);
        erc20SupraHandler.deposit{value: depositAmount}();
        erc20Supra.approve(_diamond, type(uint256).max);

        for (uint256 i = 0; i < _n; i++) {
            IRegistryFacet(_diamond).register(
                payload,
                predicate,
                _expiry,
                uint128(100_000),      // maxGasAmount
                uint128(4 gwei),       // gasPriceCap
                uint128(60.1 ether),   // automationFeeCapForCycle
                2,                     // priority
                auxData
            );
        }
        vm.stopPrank();
    }

    /// @dev Registers `_n` GST (system) tasks on `_diamond` as `bob`. GST tasks are not
    ///      charged (see LibCore.dropOrChargeTask's GST branch), so no funding is needed.
    function _registerGstTasks(address _diamond, uint256 _n) internal {
        bytes[] memory auxData;
        bytes memory payload = createPayload(
            0,
            address(erc20SupraHandler),
            abi.encodeCall(erc20SupraHandler.withdraw, 100)
        );
        bytes memory predicate = createPredicate(_diamond);
        uint64 expiry = uint64(block.timestamp + 86400);

        for (uint256 i = 0; i < _n; i++) {
            vm.prank(bob);
            IRegistryFacet(_diamond).registerSystemTask(
                payload,
                predicate,
                expiry,
                uint128(100_000),  // maxGasAmount
                2,                 // priority
                auxData
            );
        }
    }

    /// @dev Warps to the cycle boundary and measures monitorCycleEnd's gas.
    ///      gasleft() brackets (not vm.pauseGasMetering) so SLOAD/SSTORE costs are
    ///      captured faithfully - see MonitorCycleEndGas.t.sol's identical rationale.
    function _measureMonitorCycleEnd(address _diamond) internal returns (uint256 gasUsed) {
        (, uint64 startTime, uint64 durationSecs,) = ICoreFacet(_diamond).getCycleInfo();
        vm.warp(startTime + durationSecs);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);

        uint256 before = gasleft();
        ICoreFacet(_diamond).monitorCycleEnd();
        gasUsed = before - gasleft();
    }

    /// @dev Measures a single processTasks batch's gas. processTasks checks
    ///      msg.sender only (unlike monitorCycleEnd's tx.origin check), so a
    ///      single-arg prank is enough.
    function _measureProcessTasksBatch(
        address _diamond,
        uint64 _cycleIndex,
        uint256[] memory _indexes
    ) internal returns (uint256 gasUsed) {
        vm.prank(LibUtils.VM_SIGNER);

        uint256 before = gasleft();
        ICoreFacet(_diamond).processTasks(_cycleIndex, _indexes);
        gasUsed = before - gasleft();
    }

    /// @dev Builds the contiguous range of task indexes `[_start, _start + _count)`.
    function _buildRangeIndexes(uint256 _start, uint256 _count) internal pure returns (uint256[] memory indexes) {
        indexes = new uint256[](_count);
        for (uint256 i = 0; i < _count; i++) {
            indexes[i] = _start + i;
        }
    }

    /// @dev Submits all of `_taskCount` registered tasks to `_diamond` for
    ///      `_cycleIndex` as contiguous batches of BATCH_SIZE, logging and returning
    ///      each batch's gas. `_taskCount` need not be a multiple of BATCH_SIZE - the
    ///      last batch is simply smaller (custom task counts aren't guaranteed to
    ///      divide evenly).
    function _runAllBatches(
        address _diamond,
        uint64 _cycleIndex,
        uint256 _taskCount,
        string memory _logPrefix
    ) internal returns (uint256[] memory batchGas) {
        uint256 numBatches = (_taskCount + BATCH_SIZE - 1) / BATCH_SIZE;
        batchGas = new uint256[](numBatches);
        uint256 processed;
        for (uint256 b = 0; b < numBatches; b++) {
            uint256 remaining = _taskCount - processed;
            uint256 count = remaining < BATCH_SIZE ? remaining : BATCH_SIZE;
            batchGas[b] = _measureProcessTasksBatch(_diamond, _cycleIndex, _buildRangeIndexes(processed, count));
            console.log(string.concat(_logPrefix, vm.toString(b + 1), " |"), batchGas[b]);
            processed += count;
        }
    }

    /// @dev Summarizes and logs a scenario's gas figures: the triggering call
    ///      (monitorCycleEnd or disableAutomation) plus all processTasks batches,
    ///      isolating the final batch's finalization premium over a typical batch.
    ///      Returns the final batch's gas so callers can assert a sanity ceiling on it.
    function _summarizeAndLog(
        string memory _scenarioLabel,
        uint256 _triggerGas,
        uint256[] memory _batchGas
    ) internal pure returns (uint256 finalBatchGas) {
        uint256 numBatches = _batchGas.length;
        uint256 totalBatchGas;
        uint256 nonFinalTotal;
        for (uint256 b = 0; b < numBatches; b++) {
            totalBatchGas += _batchGas[b];
            if (b < numBatches - 1) {
                nonFinalTotal += _batchGas[b];
            }
        }
        uint256 nonFinalAverage = numBatches > 1 ? nonFinalTotal / (numBatches - 1) : 0;
        finalBatchGas = _batchGas[numBatches - 1];
        uint256 finalizationPremium = finalBatchGas > nonFinalAverage ? finalBatchGas - nonFinalAverage : 0;

        console.log(string.concat("=== ", _scenarioLabel, " ==="));
        console.log("trigger-call gas (monitorCycleEnd/disableAutomation)    :", _triggerGas);
        console.log("total processTasks gas (all batches)                   :", totalBatchGas);
        console.log("non-final batch average gas                            :", nonFinalAverage);
        console.log("final batch gas                                        :", finalBatchGas);
        console.log("final-batch finalization premium                       :", finalizationPremium);
        console.log("grand total (trigger + all processTasks batches)       :", _triggerGas + totalBatchGas);
    }

    // ────────────────────────────────────────────────────────────────────────
    // Scenario 1: FINISHED -> STARTED, full registry, everything survives
    // ────────────────────────────────────────────────────────────────────────

    function testCycleTransitionGas_FullFlow_ProductionMix() public {
        uint256 ustCount = _ustTaskCount();
        uint256 gstCount = _gstTaskCount();
        uint256 totalTasks = ustCount + gstCount;

        address diamond = _deployRegistry(ustCount, gstCount);
        _registerUstTasks(diamond, ustCount, uint64(block.timestamp + 86400));
        _registerGstTasks(diamond, gstCount);

        (uint64 cycleIndexBefore, , , ) = ICoreFacet(diamond).getCycleInfo();

        uint256 monitorGas = _measureMonitorCycleEnd(diamond);

        (, , , LibCommon.CycleState stateAfterMonitor) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfterMonitor), uint8(LibCommon.CycleState.FINISHED), "cycle must be FINISHED after monitorCycleEnd");

        uint256[] memory batchGas = _runAllBatches(
            diamond,
            cycleIndexBefore + 1,
            totalTasks,
            "processTasks gas | scenario 1, batch="
        );

        (uint64 cycleIndexAfter, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.STARTED), "cycle must be STARTED after full transition");
        assertEq(cycleIndexAfter, cycleIndexBefore + 1, "cycle index must increment exactly once");
        assertEq(IRegistryFacet(diamond).getActiveTaskIds().length, totalTasks, "all tasks must survive the transition");

        uint256 finalBatchGas = _summarizeAndLog(
            string.concat("Scenario 1: FINISHED->STARTED, N=", vm.toString(totalTasks), ", all survive"),
            monitorGas,
            batchGas
        );

        // Generic single-tx sanity ceiling only - see SANITY_GAS_CEILING's NatSpec.
        // A large enough custom task count can legitimately exceed this - raise it
        // (or read the logged figures directly) rather than treating a failure here
        // as a contract bug.
        assertLt(finalBatchGas, SANITY_GAS_CEILING, "final batch gas exceeds generic sanity ceiling");
    }

    // ────────────────────────────────────────────────────────────────────────
    // Scenario 2: STARTED (mid-cycle) -> SUSPENDED -> READY, full registry, everything
    // is dropped and refunded.
    // ────────────────────────────────────────────────────────────────────────

    function testCycleTransitionGas_MidCycle_StartedToSuspended_FullRegistry() public {
        uint256 ustCount = _ustTaskCount();
        uint256 gstCount = _gstTaskCount();
        uint256 totalTasks = ustCount + gstCount;

        address diamond = _deployRegistry(ustCount, gstCount);
        _registerUstTasks(diamond, ustCount, uint64(block.timestamp + 86400));
        _registerGstTasks(diamond, gstCount);

        (uint64 cycleIndex, uint64 startTime, uint64 durationSecs, ) = ICoreFacet(diamond).getCycleInfo();
        // "Middle of the cycle": halfway to cycleEndTime, well before it - disableAutomation's
        // STARTED-branch (LibCore.tryMoveToSuspendedState) reverts if currentTime >= cycleEndTime.
        vm.warp(startTime + durationSecs / 2);

        vm.prank(admin);
        uint256 before = gasleft();
        ICoreFacet(diamond).disableAutomation();
        uint256 suspendTriggerGas = before - gasleft();

        (, , , LibCommon.CycleState stateAfterDisable) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfterDisable), uint8(LibCommon.CycleState.SUSPENDED), "cycle must be SUSPENDED after mid-cycle disableAutomation");

        // onCycleSuspend checks s.index == _cycleIndex (unlike onCycleTransition's
        // index+1 - suspension does not increment the cycle index).
        uint256[] memory batchGas = _runAllBatches(
            diamond,
            cycleIndex,
            totalTasks,
            "processTasks (onCycleSuspend) gas | scenario 2, batch="
        );

        (uint64 cycleIndexAfter, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.READY), "cycle must be READY once suspension finalizes with automation disabled");
        assertEq(cycleIndexAfter, cycleIndex, "cycle index must NOT change on suspension - only STARTED transitions increment it");
        assertEq(IRegistryFacet(diamond).getActiveTaskIds().length, 0, "no tasks survive a suspension - all refunded and removed");
        assertEq(IRegistryFacet(diamond).totalTasks(), 0, "registry must be empty after full suspension");

        uint256 finalBatchGas = _summarizeAndLog(
            string.concat("Scenario 2: STARTED(mid-cycle)->SUSPENDED->READY, N=", vm.toString(totalTasks), ", all dropped"),
            suspendTriggerGas,
            batchGas
        );

        assertLt(finalBatchGas, SANITY_GAS_CEILING, "final batch gas exceeds generic sanity ceiling");
    }

    // ────────────────────────────────────────────────────────────────────────
    // Scenario 3: FINISHED -> STARTED where a subset of tasks expire mid-transition.
    //
    // LibRegistry.validateTaskDuration rejects any registration whose expiry falls
    // at or before the *current* cycle's end time, so a task can never already be
    // expired at the very first transition it survives into. To get genuinely
    // expiring tasks, this test registers EXPIRING_UST_COUNT tasks with an expiry
    // that falls inside cycle 2 (so they survive cycle 1's transition, since
    // expiry > cycle1EndTime), then runs a second cycle transition where those same
    // tasks are now past expiry (cycle2EndTime >= expiry) and get dropped instead of
    // renewed. Cycle 1's transition is just setup here; cycle 2's is the measured one.
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Default number of the UST tasks that expire mid-way, when
    ///      CYCLE_GAS_BENCH_EXPIRING_UST_COUNT is unset.
    uint256 constant EXPIRING_UST_COUNT = 20;

    function testCycleTransitionGas_FullFlow_SecondCycle_WithExpiredTasks() public {
        uint256 ustCount = _ustTaskCount();
        uint256 gstCount = _gstTaskCount();
        uint256 totalTasks = ustCount + gstCount;
        uint256 expiringCount = _expiringUstTaskCount();
        require(expiringCount <= ustCount, "CYCLE_GAS_BENCH_EXPIRING_UST_COUNT must not exceed the UST task count");

        address diamond = _deployRegistry(ustCount, gstCount);

        (, uint64 startTime1, uint64 durationSecs1, ) = ICoreFacet(diamond).getCycleInfo();
        uint64 cycle1EndTime = startTime1 + durationSecs1;
        // Falls inside cycle 2 (cycle2EndTime = cycle1EndTime + durationSecs1, and this
        // is well short of that), so registration passes but the task is expired by
        // the time cycle 2 ends.
        uint64 expiringExpiry = cycle1EndTime + 300;

        _registerUstTasks(diamond, expiringCount, expiringExpiry);
        _registerUstTasks(diamond, ustCount - expiringCount, uint64(block.timestamp + 86400));
        _registerGstTasks(diamond, gstCount);

        // ---- Cycle 1 transition: nothing has expired yet, everything survives. ----
        (uint64 cycleIndex1, , , ) = ICoreFacet(diamond).getCycleInfo();
        _measureMonitorCycleEnd(diamond);
        _runAllBatches(diamond, cycleIndex1 + 1, totalTasks, "processTasks gas | scenario 3, cycle 1 setup, batch=");
        assertEq(IRegistryFacet(diamond).getActiveTaskIds().length, totalTasks, "cycle 1: nothing expired yet, all tasks survive");

        // ---- Cycle 2 transition: the expiringCount short-expiry UST tasks are now
        // past their expiry and get dropped instead of renewed. ----
        (uint64 cycleIndex2, , , ) = ICoreFacet(diamond).getCycleInfo();
        uint256 monitorGas2 = _measureMonitorCycleEnd(diamond);

        (, , , LibCommon.CycleState stateAfterMonitor2) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfterMonitor2), uint8(LibCommon.CycleState.FINISHED), "cycle 2 must be FINISHED after monitorCycleEnd");

        uint256[] memory batchGas = _runAllBatches(
            diamond,
            cycleIndex2 + 1,
            totalTasks,
            "processTasks gas | scenario 3, cycle 2, batch="
        );

        (uint64 cycleIndex3, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.STARTED), "cycle must be STARTED after cycle 2's transition");
        assertEq(cycleIndex3, cycleIndex2 + 1, "cycle index must increment exactly once");
        assertEq(
            IRegistryFacet(diamond).getActiveTaskIds().length,
            totalTasks - expiringCount,
            "the expiring UST tasks must be dropped, the rest survive"
        );

        uint256 finalBatchGas = _summarizeAndLog(
            string.concat(
                "Scenario 3: FINISHED->STARTED (cycle 2), N=", vm.toString(totalTasks),
                " with ", vm.toString(expiringCount), " expiring"
            ),
            monitorGas2,
            batchGas
        );

        assertLt(finalBatchGas, SANITY_GAS_CEILING, "final batch gas exceeds generic sanity ceiling");
    }
}
