// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {IRegistryViewFacet} from "../src/interfaces/IRegistryViewFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {Deployment, InitParams, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";
import {Config} from "../src/libraries/LibAppStorage.sol";
import {EvmGasConfigMock} from "./EvmGasConfigMock.sol";

/// @dev Measures the execution gas of one call it makes, before refunds. The benchmark etches it
///      at LibUtils.VM_SIGNER and calls it as its own isolated transaction, so that the measured
///      call sees the registry state earlier transactions committed, and comes from VM_SIGNER as
///      monitorCycleEnd and processTasks require. A transaction's gas used, which the test sees
///      for an isolated call, has its refunds subtracted, up to a fifth of the gas (EIP-3529),
///      while a record's gas limit has to cover the gas before them; storage clears earn large
///      refunds, so a removal measured that way reads about a fifth low.
contract ExecutionGasMeter {
    /// @return gasUsed Gas the call used, refunds not subtracted.
    function measure(address _target, bytes calldata _data) external returns (uint256 gasUsed) {
        uint256 before = gasleft();
        (bool ok, bytes memory returned) = _target.call(_data);
        gasUsed = before - gasleft();
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returned, 32), mload(returned))
            }
        }
    }
}

/// @notice Gas benchmark for the automation-registry's cycle-transition flows, by
///         default at the production task-registry cap (200 tasks: 160 UST + 40 GST,
///         matching LibDiamondUtils.defaultInitParams()), submitted as batches of 25
///         tasks (BATCH_SIZE, the measurement size the record gas figures are derived
///         at). Each measured call runs as its own transaction after the registrations
///         (see the isolation note below) and is metered before refunds (ExecutionGasMeter).
///         Two further tests size the batches the way the node does, with
///         CoreFacet.getRecordMaxTaskCount, and check every record fits its gas limit
///         (testCycleTransitionGas_DerivedRecordSize_*). Every test checks its batches
///         against the record gas figures (_assertWithinRecordGasFigures).
///
///         UST/GST task counts are overridable via env vars for one-off custom-N
///         runs, without touching this file - see
///         AUTOMATION_REGISTRY_GAS_GUIDE.md's "Running with a custom task count"
///         section:
///           CYCLE_GAS_BENCH_UST_COUNT           (default 160)
///           CYCLE_GAS_BENCH_GST_COUNT           (default 40)
///           CYCLE_GAS_BENCH_EXPIRING_UST_COUNT  (default 20, scenario 3 only)
///
///   1. FINISHED -> STARTED, everything survives (testCycleTransitionGas_FullFlow_ProductionMix),
///      also run at LibCommon.RECORD_GAS_BENCHMARK_CAPACITY tasks
///      (testCycleTransitionGas_FullFlow_BenchmarkCapacity)
///   2. STARTED (mid-cycle) -> SUSPENDED -> READY, everything is dropped/refunded
///      (testCycleTransitionGas_MidCycle_StartedToSuspended_FullRegistry)
///   3. FINISHED -> STARTED with a subset of tasks expiring mid-transition
///      (testCycleTransitionGas_FullFlow_SecondCycle_WithExpiredTasks)
///   4. As 2, with every task's payload and predicate at the data-length caps
///      (testCycleTransitionGas_MidCycle_Suspension_TasksAtDataLengthCaps)
///   5. FINISHED -> STARTED after the data-length caps were lowered: half the USTs, stored at
///      the previous caps, are dropped, and every other task's stored lengths are checked
///      (testCycleTransitionGas_FullFlow_DataLengthCapsLowered)
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
///     one terminal call, regardless of which of the flows above it belongs to.
///
/// Every measurement is logged so `forge test --match-contract CycleTransitionGasTest
/// -vv` gives a ready-to-read reference, the same way MonitorCycleEndGas.t.sol does.
/// The summary across the scenarios is written up as a downstream-facing
/// reference in crates/supra-extension/src/AUTOMATION_REGISTRY_GAS_GUIDE.md.
///
/// The suite runs in isolation mode (the inline config below): every top-level call the test
/// makes, each registration and each processTasks record included, executes as its own
/// transaction with the state of the calls before it committed, as on a chain. Without it, a
/// test is one transaction, and a slot that registration wrote earlier in the same test still
/// has its original value of zero when a record clears it, so EIP-2200 prices the clear as a
/// write to a slot dirtied in the same transaction rather than as the reset of a stored value,
/// and removals measure about half their on-chain cost. vm.cool does not change original
/// values, only whether an account or slot is warm. Every measured call starts cold, as its
/// own transaction; the registry account is charged as a cold call target where a record
/// transaction has it warm as its recipient, 2,500 gas over.
/// forge-config: default.isolate = true
contract CycleTransitionGasTest is BaseDiamondTest {

    /// @dev Default UST/GST counts when CYCLE_GAS_BENCH_UST_COUNT/
    ///      CYCLE_GAS_BENCH_GST_COUNT are unset: taskCapacity=160 + sysTaskCapacity=40
    ///      = 200, matching MAX_SUPPORTED_AUTOMATION_TASKS (crates/supra-extension)
    ///      and LibDiamondUtils.defaultInitParams(). Read via _ustTaskCount()/
    ///      _gstTaskCount() rather than directly, everywhere except _deployRegistry's
    ///      "does this custom count still fit the production capacity" comparison.
    uint256 constant TOTAL_UST = 160;
    uint256 constant TOTAL_GST = 40;

    /// @dev Batch size of the three scenario tests. The node sizes its records with
    ///      CoreFacet.getRecordMaxTaskCount (Entropy-Foundation/smr-moonshot#4755), which
    ///      testCycleTransitionGas_DerivedRecordSize_FinalBatchFitsCap exercises; the scenarios
    ///      keep a fixed size so their figures, and the record gas figures derived from them,
    ///      compare across runs. Not overridable - only the task counts are, per the class's
    ///      NatSpec.
    uint256 constant BATCH_SIZE = 25;

    /// @dev Prague transaction cost constants (EIP-2028, EIP-7623), for the part of a record's
    ///      gas that the metered execution gas does not include: intrinsic gas and calldata.
    uint256 constant TX_BASE_GAS = 21_000;
    uint256 constant STANDARD_GAS_PER_TOKEN = 4;
    uint256 constant FLOOR_GAS_PER_TOKEN = 10;

    /// @dev Per-transaction gas caps the derived-size tests run at: the production cap, then
    ///      lower caps down to one task per record. Below 3,945,000 the record gas figures
    ///      leave no room for a task at a 200-task registry (see RecordSizing.t.sol).
    uint64[4] DERIVED_SIZE_CAPS = [uint64(16_777_216), 8_000_000, 6_000_000, 4_000_000];

    /// @dev Figures summarizing one run of batches; see _summarizeAndLog.
    struct BatchSummary {
        uint256 totalGas;
        uint256 initialGas;
        uint256 initialTasks;
        uint256 middleBatches;
        uint256 middleAverageGas;
        uint256 middleMaxGas;
        uint256 nonFinalMaxGasPerTask;
        uint256 nonFinalAverageGasPerTask;
        uint256 finalGas;
        uint256 finalTasks;
        uint256 finalizationPremium;
    }

    /// @dev Generic single-tx sanity ceiling, matching the pattern already used in
    ///      CoreFacet.t.sol's testStopTasksBulkRemovalFromActiveTaskIdsStaysWithinGasBudget.
    ///      It is not a record's gas limit: the node gives a record the per-transaction
    ///      cap and sizes it with CoreFacet.getRecordMaxTaskCount, which the
    ///      testCycleTransitionGas_DerivedRecordSize_* tests check against the cap.
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
        Deployment memory d = LibDiamondUtils.deploy(admin, address(wsupra), p);
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
        _registerUstTasksWith(_diamond, _n, _expiry, _fixturePayload(), createPredicate(_diamond));
    }

    /// @dev The payload the fixture tasks carry: a WrappedSupra.withdraw call with a two-entry
    ///      access list (BaseDiamondTest.createPayload), 640 bytes encoded.
    function _fixturePayload() internal view returns (bytes memory) {
        return createPayload(0, address(wsupra), abi.encodeCall(wsupra.withdraw, 100));
    }

    /// @dev _registerUstTasks with an explicit payload and predicate.
    function _registerUstTasksWith(
        address _diamond,
        uint256 _n,
        uint64 _expiry,
        bytes memory _payload,
        bytes memory _predicate
    ) internal {
        bytes[] memory noAuxData;
        _registerUstTasksWithAux(_diamond, _n, _expiry, _payload, _predicate, noAuxData);
    }

    /// @dev _registerUstTasksWith with explicit auxData.
    function _registerUstTasksWithAux(
        address _diamond,
        uint256 _n,
        uint64 _expiry,
        bytes memory _payload,
        bytes memory _predicate,
        bytes[] memory _auxData
    ) internal {
        uint256 depositAmount = _n * 200 ether;
        vm.deal(alice, depositAmount + 100 ether);

        bytes[] memory auxData = _auxData;
        bytes memory payload = _payload;
        bytes memory predicate = _predicate;

        vm.startPrank(alice);
        wsupra.deposit{value: depositAmount}();
        wsupra.approve(_diamond, type(uint256).max);

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
        _registerGstTasksWith(_diamond, _n, _fixturePayload(), createPredicate(_diamond));
    }

    /// @dev _registerGstTasks with an explicit payload and predicate.
    function _registerGstTasksWith(
        address _diamond,
        uint256 _n,
        bytes memory _payload,
        bytes memory _predicate
    ) internal {
        bytes[] memory auxData;
        bytes memory payload = _payload;
        bytes memory predicate = _predicate;
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

    /// @dev Execution gas, before refunds, of `_data` sent to `_diamond` from VM_SIGNER as its
    ///      own transaction (ExecutionGasMeter): the gas a record's limit has to cover apart from
    ///      intrinsic gas and calldata, which _requiredGasLimit adds.
    function _meteredVmSignerCall(address _diamond, bytes memory _data) internal returns (uint256) {
        if (LibUtils.VM_SIGNER.code.length == 0) {
            vm.etch(LibUtils.VM_SIGNER, type(ExecutionGasMeter).runtimeCode);
        }
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        return ExecutionGasMeter(LibUtils.VM_SIGNER).measure(_diamond, _data);
    }

    /// @dev Warps to the cycle boundary and measures monitorCycleEnd's execution gas, before
    ///      refunds, as the BlockMeta prologue's call to it spends it (_meteredVmSignerCall).
    function _measureMonitorCycleEnd(address _diamond) internal returns (uint256 gasUsed) {
        (, uint64 startTime, uint64 durationSecs,) = ICoreFacet(_diamond).getCycleInfo();
        vm.warp(startTime + durationSecs);
        gasUsed = _meteredVmSignerCall(_diamond, abi.encodeCall(ICoreFacet.monitorCycleEnd, ()));
    }

    /// @dev Measures a single processTasks batch's execution gas, before refunds, as its own
    ///      transaction (_meteredVmSignerCall).
    function _measureProcessTasksBatch(
        address _diamond,
        uint64 _cycleIndex,
        uint64[] memory _indexes
    ) internal returns (uint256 gasUsed) {
        gasUsed = _meteredVmSignerCall(_diamond, abi.encodeCall(ICoreFacet.processTasks, (_cycleIndex, _indexes)));
    }

    /// @dev Builds the contiguous range of task indexes `[_start, _start + _count)`.
    function _buildRangeIndexes(uint256 _start, uint256 _count) internal pure returns (uint64[] memory indexes) {
        indexes = new uint64[](_count);
        for (uint256 i = 0; i < _count; i++) {
            // Task indexes are bounded by the registry's task capacity, far below 2^64.
            // forge-lint: disable-next-line(unsafe-typecast)
            indexes[i] = uint64(_start + i);
        }
    }

    /// @dev Submits all of `_taskCount` registered tasks to `_diamond` for `_cycleIndex` as
    ///      contiguous batches of BATCH_SIZE, logging and returning each batch's gas and task
    ///      count. `_taskCount` need not be a multiple of BATCH_SIZE - the last batch is simply
    ///      smaller (custom task counts aren't guaranteed to divide evenly).
    function _runAllBatches(
        address _diamond,
        uint64 _cycleIndex,
        uint256 _taskCount,
        string memory _logPrefix
    ) internal returns (uint256[] memory batchGas, uint256[] memory batchTasks) {
        return _runBatches(_diamond, _cycleIndex, _taskCount, BATCH_SIZE, false, _logPrefix);
    }

    /// @dev Submits all of `_taskCount` registered tasks as contiguous batches of at most
    ///      `_batchSize`, logging and returning each batch's gas and task count.
    ///      With `_finalBatchFull` false the remainder goes last, as the node's chunking puts it
    ///      (`[n, n, ..., N mod n]`). With it true the remainder goes first (`[N mod n, n, ...]`),
    ///      so the batch that finalizes the transition carries a full `_batchSize` tasks on top of
    ///      the finalization cost: the most expensive record a transition can contain.
    function _runBatches(
        address _diamond,
        uint64 _cycleIndex,
        uint256 _taskCount,
        uint256 _batchSize,
        bool _finalBatchFull,
        string memory _logPrefix
    ) internal returns (uint256[] memory batchGas, uint256[] memory batchTasks) {
        batchTasks = _batchPlan(_taskCount, _batchSize, _finalBatchFull);
        batchGas = new uint256[](batchTasks.length);
        uint256 processed;
        for (uint256 b = 0; b < batchTasks.length; b++) {
            batchGas[b] = _measureProcessTasksBatch(_diamond, _cycleIndex, _buildRangeIndexes(processed, batchTasks[b]));
            _logBatch(_logPrefix, b, batchTasks[b], batchGas[b]);
            processed += batchTasks[b];
        }
    }

    /// @dev Task counts of the batches `_taskCount` tasks are split into: `_batchSize` each,
    ///      except the batch that takes the remainder (if non-zero), which is the first batch when
    ///      `_finalBatchFull` and the last otherwise. A separate function keeps _runBatches' locals
    ///      within the stack limit.
    function _batchPlan(uint256 _taskCount, uint256 _batchSize, bool _finalBatchFull)
        internal
        pure
        returns (uint256[] memory batchTasks)
    {
        require(_batchSize > 0, "batch size must be non-zero");
        uint256 numBatches = (_taskCount + _batchSize - 1) / _batchSize;
        uint256 remainder = _taskCount % _batchSize;
        batchTasks = new uint256[](numBatches);
        for (uint256 b = 0; b < numBatches; b++) {
            batchTasks[b] = _batchSize;
            if (remainder != 0 && (_finalBatchFull ? b == 0 : b == numBatches - 1)) {
                batchTasks[b] = remainder;
            }
        }
    }

    /// @dev Logs one batch's gas. A separate function keeps _runBatches' locals within the
    ///      stack limit.
    function _logBatch(string memory _logPrefix, uint256 _batch, uint256 _tasks, uint256 _gas) internal pure {
        console.log(string.concat(_logPrefix, vm.toString(_batch + 1), " (", vm.toString(_tasks), " tasks) |"), _gas);
    }

    /// @dev Summarizes and logs a scenario's gas figures: the triggering call (monitorCycleEnd or
    ///      disableAutomation), the initial batch, the middle batches (all but the first and the
    ///      last), the final batch, each with its gas per task, and the finalization premium: the
    ///      final batch's gas less its tasks priced at the non-final batches' average gas per task.
    function _summarizeAndLog(
        string memory _scenarioLabel,
        uint256 _triggerGas,
        uint256[] memory _batchGas,
        uint256[] memory _batchTasks
    ) internal pure returns (BatchSummary memory sum) {
        uint256 numBatches = _batchGas.length;
        require(numBatches > 0 && numBatches == _batchTasks.length, "batch figures must be non-empty and paired");

        uint256 nonFinalGas;
        uint256 nonFinalTasks;
        uint256 middleGas;
        for (uint256 b = 0; b < numBatches; b++) {
            sum.totalGas += _batchGas[b];
            if (b == numBatches - 1) { continue; }
            nonFinalGas += _batchGas[b];
            nonFinalTasks += _batchTasks[b];
            uint256 perTask = _batchGas[b] / _batchTasks[b];
            if (perTask > sum.nonFinalMaxGasPerTask) { sum.nonFinalMaxGasPerTask = perTask; }
            if (b > 0) {
                sum.middleBatches += 1;
                middleGas += _batchGas[b];
                if (_batchGas[b] > sum.middleMaxGas) { sum.middleMaxGas = _batchGas[b]; }
            }
        }
        if (numBatches > 1) {
            sum.initialGas = _batchGas[0];
            sum.initialTasks = _batchTasks[0];
            sum.nonFinalAverageGasPerTask = nonFinalGas / nonFinalTasks;
        }
        if (sum.middleBatches > 0) { sum.middleAverageGas = middleGas / sum.middleBatches; }
        sum.finalGas = _batchGas[numBatches - 1];
        sum.finalTasks = _batchTasks[numBatches - 1];
        uint256 finalTasksAtAverage = sum.finalTasks * sum.nonFinalAverageGasPerTask;
        sum.finalizationPremium = sum.finalGas > finalTasksAtAverage ? sum.finalGas - finalTasksAtAverage : 0;

        console.log(string.concat("=== ", _scenarioLabel, " ==="));
        console.log("trigger-call gas (monitorCycleEnd/disableAutomation)    :", _triggerGas);
        console.log("total processTasks gas (all batches)                   :", sum.totalGas);
        console.log("initial batch gas                                      :", sum.initialGas);
        console.log("initial batch gas per task                             :", sum.initialTasks == 0 ? 0 : sum.initialGas / sum.initialTasks);
        console.log("middle batches                                         :", sum.middleBatches);
        console.log("middle batch average gas                               :", sum.middleAverageGas);
        console.log("middle batch max gas                                   :", sum.middleMaxGas);
        console.log("non-final batch average gas per task                   :", sum.nonFinalAverageGasPerTask);
        console.log("non-final batch max gas per task                       :", sum.nonFinalMaxGasPerTask);
        console.log("final batch gas                                        :", sum.finalGas);
        console.log("final batch tasks                                      :", sum.finalTasks);
        console.log("final-batch finalization premium                       :", sum.finalizationPremium);
        console.log("grand total (trigger + all processTasks batches)       :", _triggerGas + sum.totalGas);
    }

    /// @dev Number of tasks `_diamond` can hold under its active config, the capacity
    ///      CoreFacet.getRecordMaxTaskCount reserves finalization gas for.
    function _capacity(address _diamond) internal view returns (uint256) {
        Config memory cfg = IConfigFacet(_diamond).getConfig();
        return uint256(cfg.taskCapacity) + uint256(cfg.sysTaskCapacity);
    }

    /// @dev Gas one task can add to a record under the benchmark-derived gas figures and
    ///      `_diamond`'s stored-words bound, computed with the same LibCommon helper
    ///      CoreFacet.getRecordMaxTaskCount uses.
    function _recordTaskGas(address _diamond) internal view returns (uint256) {
        return LibCommon.recordTaskGas(IConfigFacet(_diamond).getTaskStoredWordsBound());
    }

    /// @dev Checks the measured batches against the benchmark-derived record gas figures
    ///      (LibCommon.RECORD_GAS_*, Entropy-Foundation/smr-moonshot#4755).
    ///      CoreFacet.getRecordMaxTaskCount gives every record k tasks at _recordTaskGas each
    ///      plus the finalization reserve, capacity * RECORD_FINALIZATION_GAS_PER_TASK, since the
    ///      node does not know which record finalizes. Asserted here:
    ///      - every batch costs at most k * _recordTaskGas + reserve, the bound the view sizes
    ///        records with. The reserve also absorbs the fixed cost of a processTasks call,
    ///        which the per-task figures do not carry: a non-final record never spends it on
    ///        finalization, and the final record's premium leaves part of it unspent
    ///        (_assertPremiumWithinReserve).
    ///      - a non-final batch of BATCH_SIZE tasks costs at most BATCH_SIZE * _recordTaskGas,
    ///        so the per-task figures cover the marginal cost of a task with the call's fixed
    ///        cost spread over a full batch, the measurement they are derived from.
    ///      A contract change that raises a cost above its figure fails here, so the figures are
    ///      re-derived with the change; the logged per-task figures and premium are the inputs.
    function _assertWithinRecordGasFigures(
        address _diamond,
        uint256[] memory _batchGas,
        uint256[] memory _batchTasks
    ) internal view {
        _assertWithinRecordGasFiguresAt(
            _recordTaskGas(_diamond), _finalizationReserve(_diamond), _batchGas, _batchTasks
        );
    }

    /// @dev _assertWithinRecordGasFigures for a task gas and reserve the caller captured, for a
    ///      transition after which the registry's stored-words bound differs from the one its
    ///      records were sized with (scenario 5).
    function _assertWithinRecordGasFiguresAt(
        uint256 _taskGas,
        uint256 _reserve,
        uint256[] memory _batchGas,
        uint256[] memory _batchTasks
    ) internal pure {
        uint256 taskGas = _taskGas;
        uint256 reserve = _reserve;
        uint256 last = _batchGas.length - 1;
        for (uint256 b = 0; b <= last; b++) {
            assertLe(
                _batchGas[b],
                _batchTasks[b] * taskGas + reserve,
                string.concat("batch ", vm.toString(b + 1), " exceeds the record gas figures")
            );
            if (b != last && _batchTasks[b] == BATCH_SIZE) {
                assertLe(
                    _batchGas[b],
                    BATCH_SIZE * taskGas,
                    string.concat("batch ", vm.toString(b + 1), " exceeds the per-task record gas figures")
                );
            }
        }
    }

    /// @dev The finalization reserve every record carries under the benchmark-derived gas figures
    ///      and `_diamond`'s active capacity.
    function _finalizationReserve(address _diamond) internal view returns (uint256) {
        return _capacity(_diamond) * uint256(LibCommon.RECORD_FINALIZATION_GAS_PER_TASK);
    }

    /// @dev The final batch's finalization premium (see _summarizeAndLog) is within the
    ///      finalization reserve.
    function _assertPremiumWithinReserve(address _diamond, BatchSummary memory _summary) internal view {
        assertLe(
            _summary.finalizationPremium,
            _finalizationReserve(_diamond),
            "finalization premium exceeds the record finalization figure"
        );
    }

    /// @dev Gas limit a transaction with `_calldata` needs for an execution frame of
    ///      `_execution` gas: intrinsic gas plus calldata plus execution, and at least the
    ///      EIP-7623 calldata floor. Refunds are not subtracted - they are credited only after
    ///      execution, so the limit must cover the gas before them.
    function _requiredGasLimit(bytes memory _calldata, uint256 _execution) internal pure returns (uint256) {
        uint256 tokens;
        for (uint256 i = 0; i < _calldata.length; i++) {
            tokens += _calldata[i] == 0 ? 1 : 4;
        }
        uint256 standard = TX_BASE_GAS + STANDARD_GAS_PER_TOKEN * tokens + _execution;
        uint256 floor = TX_BASE_GAS + FLOOR_GAS_PER_TOKEN * tokens;
        return standard > floor ? standard : floor;
    }

    // ────────────────────────────────────────────────────────────────────────
    // Scenario 1: FINISHED -> STARTED, full registry, everything survives
    // ────────────────────────────────────────────────────────────────────────

    function testCycleTransitionGas_FullFlow_ProductionMix() public {
        _runFullFlowAllSurvive(_ustTaskCount(), _gstTaskCount(), "Scenario 1: FINISHED->STARTED, N=");
    }

    /// @dev Scenario 1 at LibCommon.RECORD_GAS_BENCHMARK_CAPACITY tasks (80% user, 20% system,
    ///      the production split), the capacity the record gas figures are measured at and the
    ///      default RecordSizingParameters.maxCapacity. The finalization premium per task grows
    ///      with the registry, so this is where LibCommon.RECORD_FINALIZATION_GAS_PER_TASK is
    ///      tightest; running it in every suite run keeps the limit checked at the capacity
    ///      updateConfigBuffer accepts by default.
    function testCycleTransitionGas_FullFlow_BenchmarkCapacity() public {
        uint256 capacity = LibCommon.RECORD_GAS_BENCHMARK_CAPACITY;
        _runFullFlowAllSurvive(capacity * 4 / 5, capacity / 5, "Scenario 1 at the benchmark capacity: FINISHED->STARTED, N=");
    }

    /// @dev Scenario 1: registers `_ustCount` USTs and `_gstCount` GSTs, ends the cycle, and
    ///      processes the FINISHED -> STARTED transition in which every task survives.
    function _runFullFlowAllSurvive(uint256 _ustCount, uint256 _gstCount, string memory _label) internal {
        uint256 ustCount = _ustCount;
        uint256 gstCount = _gstCount;
        uint256 totalTasks = ustCount + gstCount;
        address diamond = _deployRegistry(ustCount, gstCount);
        _registerUstTasks(diamond, ustCount, uint64(block.timestamp + 86400));
        _registerGstTasks(diamond, gstCount);

        (uint64 cycleIndexBefore, , , ) = ICoreFacet(diamond).getCycleInfo();

        uint256 monitorGas = _measureMonitorCycleEnd(diamond);

        (, , , LibCommon.CycleState stateAfterMonitor) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfterMonitor), uint8(LibCommon.CycleState.FINISHED), "cycle must be FINISHED after monitorCycleEnd");

        (uint256[] memory batchGas, uint256[] memory batchTasks) = _runAllBatches(
            diamond,
            cycleIndexBefore + 1,
            totalTasks,
            "processTasks gas | scenario 1, batch="
        );

        (uint64 cycleIndexAfter, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.STARTED), "cycle must be STARTED after full transition");
        assertEq(cycleIndexAfter, cycleIndexBefore + 1, "cycle index must increment exactly once");
        assertEq(IRegistryViewFacet(diamond).getActiveTaskIds().length, totalTasks, "all tasks must survive the transition");

        BatchSummary memory summary = _summarizeAndLog(
            string.concat(_label, vm.toString(totalTasks), ", all survive"),
            monitorGas,
            batchGas,
            batchTasks
        );

        // Generic single-tx sanity ceiling only - see SANITY_GAS_CEILING's NatSpec.
        // A large enough custom task count can legitimately exceed this - raise it
        // (or read the logged figures directly) rather than treating a failure here
        // as a contract bug.
        assertLt(summary.finalGas, SANITY_GAS_CEILING, "final batch gas exceeds generic sanity ceiling");

        // The first transition writes the survivor lists into fresh slots, the most
        // expensive finalization (see AUTOMATION_REGISTRY_GAS_GUIDE.md, scenario 3), so the
        // record gas figures are derived from this scenario's logged figures.
        console.log("finalization premium per registered task               :", summary.finalizationPremium / _capacity(diamond));
        _assertWithinRecordGasFigures(diamond, batchGas, batchTasks);
        _assertPremiumWithinReserve(diamond, summary);
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
        (uint256[] memory batchGas, uint256[] memory batchTasks) = _runAllBatches(
            diamond,
            cycleIndex,
            totalTasks,
            "processTasks (onCycleSuspend) gas | scenario 2, batch="
        );

        (uint64 cycleIndexAfter, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.READY), "cycle must be READY once suspension finalizes with automation disabled");
        assertEq(cycleIndexAfter, cycleIndex, "cycle index must NOT change on suspension - only STARTED transitions increment it");
        assertEq(IRegistryViewFacet(diamond).getActiveTaskIds().length, 0, "no tasks survive a suspension - all refunded and removed");
        assertEq(IRegistryViewFacet(diamond).totalTasks(), 0, "registry must be empty after full suspension");

        BatchSummary memory summary = _summarizeAndLog(
            string.concat("Scenario 2: STARTED(mid-cycle)->SUSPENDED->READY, N=", vm.toString(totalTasks), ", all dropped"),
            suspendTriggerGas,
            batchGas,
            batchTasks
        );

        assertLt(summary.finalGas, SANITY_GAS_CEILING, "final batch gas exceeds generic sanity ceiling");
        _assertWithinRecordGasFigures(diamond, batchGas, batchTasks);
        _assertPremiumWithinReserve(diamond, summary);
    }

    // ────────────────────────────────────────────────────────────────────────
    // Scenario 4: STARTED (mid-cycle) -> SUSPENDED -> READY like scenario 2, with every
    // task's payload and predicate at the registry's data-length caps.
    //
    // Removing a task deletes its whole record, payload and predicate included
    // (LibCommon.removeTask), one cold slot clear per 32 bytes stored, so the gas a removed
    // task adds to a record grows with the size of the task. A batch that removes only
    // cap-size tasks is the most expensive per task a record can carry; this scenario
    // measures it.
    // ────────────────────────────────────────────────────────────────────────

    function testCycleTransitionGas_MidCycle_Suspension_TasksAtDataLengthCaps() public {
        uint256 ustCount = _ustTaskCount();
        uint256 gstCount = _gstTaskCount();
        uint256 totalTasks = ustCount + gstCount;

        address diamond = _deployRegistry(ustCount, gstCount);
        uint16 maxPayload = IConfigFacet(diamond).getDataLengthCaps().maxPayloadLength;
        uint16 maxPredicate = IConfigFacet(diamond).getDataLengthCaps().maxPredicateLength;
        bytes memory payload = payloadOfExactLength(maxPayload);
        bytes memory predicate = predicateOfExactLength(diamond, maxPredicate);
        _registerUstTasksWith(diamond, ustCount, uint64(block.timestamp + 86400), payload, predicate);
        _registerGstTasksWith(diamond, gstCount, payload, predicate);

        (uint64 cycleIndex, uint64 startTime, uint64 durationSecs, ) = ICoreFacet(diamond).getCycleInfo();
        vm.warp(startTime + durationSecs / 2);

        vm.prank(admin);
        uint256 before = gasleft();
        ICoreFacet(diamond).disableAutomation();
        uint256 suspendTriggerGas = before - gasleft();

        (uint256[] memory batchGas, uint256[] memory batchTasks) = _runAllBatches(
            diamond,
            cycleIndex,
            totalTasks,
            "processTasks (onCycleSuspend) gas | scenario 4, batch="
        );

        (, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.READY), "cycle must be READY once suspension finalizes with automation disabled");
        assertEq(IRegistryViewFacet(diamond).totalTasks(), 0, "registry must be empty after full suspension");

        BatchSummary memory summary = _summarizeAndLog(
            string.concat(
                "Scenario 4: STARTED(mid-cycle)->SUSPENDED->READY, N=", vm.toString(totalTasks),
                ", payload ", vm.toString(payload.length), " B, predicate ", vm.toString(predicate.length), " B"
            ),
            suspendTriggerGas,
            batchGas,
            batchTasks
        );

        assertLt(summary.finalGas, SANITY_GAS_CEILING, "final batch gas exceeds generic sanity ceiling");
        _assertWithinRecordGasFigures(diamond, batchGas, batchTasks);
        _assertPremiumWithinReserve(diamond, summary);
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

    /// @dev Scenario 5: the owner lowers the data-length caps while tasks stored at the previous
    ///      caps are registered (ConfigFacet.updateDataLengthCaps, Entropy-Foundation/smr-moonshot#4755).
    ///      The caps apply in monitorCycleEnd, and the transition drops every task above them
    ///      with its deposit refunded, and checks the stored lengths of every other task. The
    ///      records are sized for the previous caps' stored-words bound until the transition
    ///      finalizes, so the batches are asserted against that bound. Tasks are processed in
    ///      index order: the oversized USTs, registered first, fill the first batches, so both a
    ///      batch of drops and a batch of checked survivors are measured.
    function testCycleTransitionGas_FullFlow_DataLengthCapsLowered() public {
        uint256 ustCount = _ustTaskCount();
        uint256 gstCount = _gstTaskCount();
        uint256 totalTasks = ustCount + gstCount;
        uint256 oversizedCount = ustCount / 2;

        address diamond = _deployRegistry(ustCount, gstCount);
        uint16 maxPayload = IConfigFacet(diamond).getDataLengthCaps().maxPayloadLength;
        uint16 maxPredicate = IConfigFacet(diamond).getDataLengthCaps().maxPredicateLength;
        _registerUstTasksWith(
            diamond,
            oversizedCount,
            uint64(block.timestamp + 86400),
            payloadOfExactLength(maxPayload),
            predicateOfExactLength(diamond, maxPredicate)
        );
        _registerUstTasks(diamond, ustCount - oversizedCount, uint64(block.timestamp + 86400));
        _registerGstTasks(diamond, gstCount);

        // The fixture's 640-byte payload and 128-byte predicate fit the lower caps; the
        // cap-size tasks do not.
        vm.prank(admin);
        IConfigFacet(diamond).updateDataLengthCaps(1024, 512, 0, 0);

        (uint64 cycleIndexBefore, , , ) = ICoreFacet(diamond).getCycleInfo();
        uint256 monitorGas = _measureMonitorCycleEnd(diamond);

        // The lower caps are in force, and records are sized for the previous ones.
        uint16 payloadCap = IConfigFacet(diamond).getDataLengthCaps().maxPayloadLength;
        assertEq(payloadCap, 1024, "lower caps apply in monitorCycleEnd");
        uint32 boundDuringTransition = IConfigFacet(diamond).getTaskStoredWordsBound();
        assertEq(boundDuringTransition, uint32(maxPayload / 32 + maxPredicate / 32), "bound stays at the previous caps");
        uint256 taskGas = _recordTaskGas(diamond);
        uint256 reserve = _finalizationReserve(diamond);

        (uint256[] memory batchGas, uint256[] memory batchTasks) = _runAllBatches(
            diamond,
            cycleIndexBefore + 1,
            totalTasks,
            "processTasks gas | scenario 5, batch="
        );

        (, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.STARTED), "cycle must be STARTED after full transition");
        assertEq(
            IRegistryViewFacet(diamond).getActiveTaskIds().length,
            totalTasks - oversizedCount,
            "the tasks above the lower caps are dropped"
        );
        assertEq(IConfigFacet(diamond).getTaskStoredWordsBound(), 1024 / 32 + 512 / 32, "bound follows the caps once finalized");

        BatchSummary memory summary = _summarizeAndLog(
            string.concat(
                "Scenario 5: FINISHED->STARTED, caps lowered, N=", vm.toString(totalTasks),
                ", dropped ", vm.toString(oversizedCount)
            ),
            monitorGas,
            batchGas,
            batchTasks
        );

        assertLt(summary.finalGas, SANITY_GAS_CEILING, "final batch gas exceeds generic sanity ceiling");
        _assertWithinRecordGasFiguresAt(taskGas, reserve, batchGas, batchTasks);
        assertLe(summary.finalizationPremium, reserve, "finalization premium exceeds the record finalization figure");
    }

    /// @dev auxData shape of scenario 6: AUX_ENTRY_COUNT entries of one byte each. A byte array
    ///      of up to 31 bytes is stored in a single slot together with its length, so each entry
    ///      is one slot to read and one to clear, the most slots per entry byte, while
    ///      LibCommon.recordStoredWords charges two words per entry plus the words of the combined
    ///      length.
    uint256 constant AUX_ENTRY_COUNT = 64;

    /// @dev Scenario 6: scenario 5 for auxData. The USTs carry AUX_ENTRY_COUNT one-byte auxData
    ///      entries under caps that admit exactly that (Entropy-Foundation/smr-moonshot#4755),
    ///      with the payload and predicate caps at the fixture's sizes, so the stored-words bound
    ///      is dominated by auxData. The combined-length cap is then lowered by one byte, keeping
    ///      the entry cap: LibCore.exceedsDataLengthCaps reads every entry's length before it
    ///      finds the task above the caps, the costliest check, and the transition then clears
    ///      every entry. The batches are asserted against the record gas figures at the previous
    ///      caps' bound, as in scenario 5, so the per-entry words recordStoredWords charges are
    ///      checked against a measured drop.
    function testCycleTransitionGas_FullFlow_AuxDataCapsLowered() public {
        uint256 ustCount = _ustTaskCount();
        uint256 gstCount = _gstTaskCount();
        uint256 totalTasks = ustCount + gstCount;
        uint16 entries = uint16(AUX_ENTRY_COUNT);

        address diamond = _deployRegistry(ustCount, gstCount);
        bytes memory payload = _fixturePayload();
        bytes memory predicate = createPredicate(diamond);
        // Caps at the fixture's payload and predicate sizes, admitting the auxData exactly; with
        // no task registered they apply at the first boundary, and so does the bound.
        vm.prank(admin);
        IConfigFacet(diamond).updateDataLengthCaps(
            uint16(payload.length), uint16(predicate.length), entries, entries
        );
        endCycleAsVmSigner(diamond);

        bytes[] memory auxData = new bytes[](AUX_ENTRY_COUNT);
        for (uint256 i = 0; i < AUX_ENTRY_COUNT; i++) {
            auxData[i] = hex"ff";
        }
        _registerUstTasksWithAux(diamond, ustCount, uint64(block.timestamp + 86400 * 2), payload, predicate, auxData);
        _registerGstTasks(diamond, gstCount);

        vm.prank(admin);
        IConfigFacet(diamond).updateDataLengthCaps(
            uint16(payload.length), uint16(predicate.length), entries - 1, entries
        );

        (uint64 cycleIndexBefore, , , ) = ICoreFacet(diamond).getCycleInfo();
        uint256 monitorGas = _measureMonitorCycleEnd(diamond);
        uint256 taskGas = _recordTaskGas(diamond);
        uint256 reserve = _finalizationReserve(diamond);

        (uint256[] memory batchGas, uint256[] memory batchTasks) = _runAllBatches(
            diamond,
            cycleIndexBefore + 1,
            totalTasks,
            "processTasks gas | scenario 6, batch="
        );

        assertEq(
            IRegistryViewFacet(diamond).getActiveTaskIds().length,
            gstCount,
            "every UST is above the lowered combined-length cap"
        );

        BatchSummary memory summary = _summarizeAndLog(
            string.concat(
                "Scenario 6: FINISHED->STARTED, auxData caps lowered, N=", vm.toString(totalTasks),
                ", auxData entries per UST ", vm.toString(AUX_ENTRY_COUNT),
                ", record task gas ", vm.toString(taskGas)
            ),
            monitorGas,
            batchGas,
            batchTasks
        );

        assertLt(summary.finalGas, SANITY_GAS_CEILING, "final batch gas exceeds generic sanity ceiling");
        _assertWithinRecordGasFiguresAt(taskGas, reserve, batchGas, batchTasks);
        assertLe(summary.finalizationPremium, reserve, "finalization premium exceeds the record finalization figure");
    }

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
        assertEq(IRegistryViewFacet(diamond).getActiveTaskIds().length, totalTasks, "cycle 1: nothing expired yet, all tasks survive");

        // ---- Cycle 2 transition: the expiringCount short-expiry UST tasks are now
        // past their expiry and get dropped instead of renewed. ----
        (uint64 cycleIndex2, , , ) = ICoreFacet(diamond).getCycleInfo();
        uint256 monitorGas2 = _measureMonitorCycleEnd(diamond);

        (, , , LibCommon.CycleState stateAfterMonitor2) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfterMonitor2), uint8(LibCommon.CycleState.FINISHED), "cycle 2 must be FINISHED after monitorCycleEnd");

        (uint256[] memory batchGas, uint256[] memory batchTasks) = _runAllBatches(
            diamond,
            cycleIndex2 + 1,
            totalTasks,
            "processTasks gas | scenario 3, cycle 2, batch="
        );

        (uint64 cycleIndex3, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.STARTED), "cycle must be STARTED after cycle 2's transition");
        assertEq(cycleIndex3, cycleIndex2 + 1, "cycle index must increment exactly once");
        assertEq(
            IRegistryViewFacet(diamond).getActiveTaskIds().length,
            totalTasks - expiringCount,
            "the expiring UST tasks must be dropped, the rest survive"
        );

        BatchSummary memory summary = _summarizeAndLog(
            string.concat(
                "Scenario 3: FINISHED->STARTED (cycle 2), N=", vm.toString(totalTasks),
                " with ", vm.toString(expiringCount), " expiring"
            ),
            monitorGas2,
            batchGas,
            batchTasks
        );

        assertLt(summary.finalGas, SANITY_GAS_CEILING, "final batch gas exceeds generic sanity ceiling");
        _assertWithinRecordGasFigures(diamond, batchGas, batchTasks);
        _assertPremiumWithinReserve(diamond, summary);
    }

    // ────────────────────────────────────────────────────────────────────────
    // Derived record size: the node's sizing, CoreFacet.getRecordMaxTaskCount
    // (Entropy-Foundation/smr-moonshot#4755), at a full registry.
    // ────────────────────────────────────────────────────────────────────────

    /// @dev FINISHED -> STARTED with every task surviving, the transition whose final batch
    ///      pays the largest finalization cost (scenario 1), at each cap in DERIVED_SIZE_CAPS.
    function testCycleTransitionGas_DerivedRecordSize_FinalBatchFitsCap() public {
        for (uint256 c = 0; c < DERIVED_SIZE_CAPS.length; c++) {
            _runDerivedSizeTransition(DERIVED_SIZE_CAPS[c], false);
        }
    }

    /// @dev STARTED -> SUSPENDED with every task at the data-length caps, the batches with the
    ///      largest per-task cost (scenario 4), at each cap in DERIVED_SIZE_CAPS.
    function testCycleTransitionGas_DerivedRecordSize_CapSizeRemovalsFitCap() public {
        for (uint256 c = 0; c < DERIVED_SIZE_CAPS.length; c++) {
            _runDerivedSizeTransition(DERIVED_SIZE_CAPS[c], true);
        }
    }

    /// @dev On a fresh registry (a transition finalizes once), with the gas config precompile
    ///      serving `_cap`: register the full registry, start a transition, size the batches
    ///      with getRecordMaxTaskCount(_cap) and run them with the final batch carrying a full
    ///      batch of tasks. Every batch, with the intrinsic and calldata gas its metered
    ///      execution gas does not include, must fit `_cap`, the gas limit the node gives each
    ///      record.
    ///      `_suspendCapSizeTasks` false ends the cycle with fixture-size tasks that all survive;
    ///      true registers tasks at the data-length caps and suspends mid-cycle, so every task
    ///      is removed. The task counts follow the CYCLE_GAS_BENCH_* overrides; a larger
    ///      registry raises the finalization reserve and the view returns a smaller size.
    function _runDerivedSizeTransition(uint64 _cap, bool _suspendCapSizeTasks) internal {
        uint256 ustCount = _ustTaskCount();
        uint256 gstCount = _gstTaskCount();
        uint256 totalTasks = ustCount + gstCount;

        // The registry checks a task's maxGasAmount against the cap at registration.
        EvmGasConfigMock.mockTxGasLimitCap(vm, _cap);
        address diamond = _deployRegistry(ustCount, gstCount);

        uint64 cycleIndex;
        if (_suspendCapSizeTasks) {
            uint16 maxPayload = IConfigFacet(diamond).getDataLengthCaps().maxPayloadLength;
            uint16 maxPredicate = IConfigFacet(diamond).getDataLengthCaps().maxPredicateLength;
            bytes memory payload = payloadOfExactLength(maxPayload);
            bytes memory predicate = predicateOfExactLength(diamond, maxPredicate);
            _registerUstTasksWith(diamond, ustCount, uint64(block.timestamp + 86400), payload, predicate);
            _registerGstTasksWith(diamond, gstCount, payload, predicate);

            uint64 startTime;
            uint64 durationSecs;
            (cycleIndex, startTime, durationSecs, ) = ICoreFacet(diamond).getCycleInfo();
            vm.warp(startTime + durationSecs / 2);
            vm.prank(admin);
            ICoreFacet(diamond).disableAutomation();
        } else {
            _registerUstTasks(diamond, ustCount, uint64(block.timestamp + 86400));
            _registerGstTasks(diamond, gstCount);

            (cycleIndex, , , ) = ICoreFacet(diamond).getCycleInfo();
            _measureMonitorCycleEnd(diamond);
            // processTasks of a FINISHED -> STARTED transition names the next cycle.
            cycleIndex += 1;
        }

        uint256 recordSize = ICoreFacet(diamond).getRecordMaxTaskCount(_cap);
        if (recordSize == 0) {
            // Every cap in DERIVED_SIZE_CAPS carries a task at the default registry size. A
            // custom size (CYCLE_GAS_BENCH_*) can raise the finalization reserve past a low
            // cap's budget; the view then returns 0, the node pauses automation, and there is
            // no record to measure.
            assertTrue(
                ustCount != TOTAL_UST || gstCount != TOTAL_GST,
                string.concat("no task fits a record at cap ", vm.toString(_cap))
            );
            console.log("derived record size: no task fits at cap", _cap);
            return;
        }
        uint256 batchSize = recordSize < totalTasks ? recordSize : totalTasks;

        string memory label = string.concat(
            _suspendCapSizeTasks ? "derived record size, cap-size removals" : "derived record size, all survive",
            " | cap=", vm.toString(_cap), " size=", vm.toString(recordSize), ", batch="
        );
        (uint256[] memory batchGas, uint256[] memory batchTasks) =
            _runBatches(diamond, cycleIndex, totalTasks, batchSize, true, label);

        (, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamond).getCycleInfo();
        assertEq(
            uint8(stateAfter),
            uint8(_suspendCapSizeTasks ? LibCommon.CycleState.READY : LibCommon.CycleState.STARTED),
            "the transition must complete"
        );

        _assertBatchesFitCap(_cap, cycleIndex, batchGas, batchTasks, label);
        _assertWithinRecordGasFigures(diamond, batchGas, batchTasks);
    }

    /// @dev Asserts that each batch, rebuilt as the processTasks calldata the node sends, needs a
    ///      gas limit of at most `_cap` (_requiredGasLimit), and logs the largest requirement.
    function _assertBatchesFitCap(
        uint64 _cap,
        uint64 _cycleIndex,
        uint256[] memory _batchGas,
        uint256[] memory _batchTasks,
        string memory _label
    ) internal pure {
        uint256 processed;
        uint256 largest;
        for (uint256 b = 0; b < _batchGas.length; b++) {
            bytes memory callData = abi.encodeCall(
                ICoreFacet.processTasks,
                (_cycleIndex, _buildRangeIndexes(processed, _batchTasks[b]))
            );
            uint256 required = _requiredGasLimit(callData, _batchGas[b]);
            if (required > largest) { largest = required; }
            assertLe(
                required,
                _cap,
                string.concat(_label, vm.toString(b + 1), " does not fit cap ", vm.toString(_cap))
            );
            processed += _batchTasks[b];
        }
        console.log(string.concat(_label, " largest required gas limit |"), largest);
    }
}
