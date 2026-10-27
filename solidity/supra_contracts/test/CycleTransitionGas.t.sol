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
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {EvmGasConfigMock} from "./EvmGasConfigMock.sol";

/// @notice Gas benchmark for the automation-registry's cycle-transition flows, by
///         default at the production task-registry cap (200 tasks: 160 UST + 40 GST,
///         matching LibDiamondUtils.defaultInitParams()), submitted as batches of 25
///         tasks (BATCH_SIZE, the measurement size the record gas figures are derived
///         at), with the registry cooled before each processTasks call (_coolRegistry).
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
///   1. FINISHED -> STARTED, everything survives (testCycleTransitionGas_FullFlow_ProductionMix)
///   2. STARTED (mid-cycle) -> SUSPENDED -> READY, everything is dropped/refunded
///      (testCycleTransitionGas_MidCycle_StartedToSuspended_FullRegistry)
///   3. FINISHED -> STARTED with a subset of tasks expiring mid-transition
///      (testCycleTransitionGas_FullFlow_SecondCycle_WithExpiredTasks)
///   4. As 2, with every task's payload and predicate at the data-length caps
///      (testCycleTransitionGas_MidCycle_Suspension_TasksAtDataLengthCaps)
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
    ///      gas that the gasleft() brackets do not see: intrinsic gas and calldata.
    uint256 constant TX_BASE_GAS = 21_000;
    uint256 constant STANDARD_GAS_PER_TOKEN = 4;
    uint256 constant FLOOR_GAS_PER_TOKEN = 10;

    /// @dev Per-transaction gas caps the derived-size tests run at: the production cap, then
    ///      lower caps down to one task per record. Below 2,800,000 the default figures leave
    ///      no room for a task at a 200-task registry (see RecordSizing.t.sol).
    uint64[4] DERIVED_SIZE_CAPS = [uint64(16_777_216), 8_000_000, 4_000_000, 3_000_000];

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

    /// @dev A payload of exactly `_totalLength` bytes, filled with non-zero bytes so every slot
    ///      it occupies in storage is non-zero (a zero-filled one would store and clear almost
    ///      for free). Registration only decodes the payload and length-checks its call data.
    ///      With an empty access list abi.encode(uint128, address, bytes, AccessListEntry[]) is
    ///      192 bytes plus the call data padded to 32; RegistrationGas.t.sol builds its cap-size
    ///      payloads the same way.
    function _payloadOfLength(uint256 _totalLength) internal view returns (bytes memory) {
        require(_totalLength % 32 == 0 && _totalLength > 192 + 32, "payload length");
        LibCommon.AccessListEntry[] memory emptyAccessList;
        bytes memory callData = abi.encodePacked(wsupra.withdraw.selector, _nonZeroBytes(_totalLength - 192 - 4));
        return abi.encode(uint128(0), address(wsupra), callData, emptyAccessList);
    }

    /// @dev A predicate of exactly `_totalLength` bytes. Registration executes the predicate
    ///      with a staticcall, so its call data stays a valid call: isRegistrationEnabled()
    ///      takes no arguments and ignores the trailing bytes. abi.encode(address, bytes) is
    ///      96 bytes plus the call data padded to 32.
    function _predicateOfLength(address _diamond, uint256 _totalLength) internal pure returns (bytes memory) {
        require(_totalLength % 32 == 0 && _totalLength > 96 + 32, "predicate length");
        bytes memory callData = abi.encodePacked(
            IConfigFacet.isRegistrationEnabled.selector, _nonZeroBytes(_totalLength - 96 - 4)
        );
        return abi.encode(_diamond, callData);
    }

    /// @dev Returns `_length` bytes of 0xab.
    function _nonZeroBytes(uint256 _length) internal pure returns (bytes memory out) {
        out = new bytes(_length);
        for (uint256 i = 0; i < _length; i++) {
            out[i] = 0xab;
        }
    }

    /// @dev _registerUstTasks with an explicit payload and predicate.
    function _registerUstTasksWith(
        address _diamond,
        uint256 _n,
        uint64 _expiry,
        bytes memory _payload,
        bytes memory _predicate
    ) internal {
        uint256 depositAmount = _n * 200 ether;
        vm.deal(alice, depositAmount + 100 ether);

        bytes[] memory auxData;
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

    /// @dev Marks the registry's accounts and storage cold, as at the start of a transaction.
    ///      Every record is its own transaction, while this benchmark runs all of them, and the
    ///      registrations before them, in one test transaction; without this, the task slots
    ///      registration wrote would be charged warm. The Diamond delegates to its facets, so
    ///      each facet's code account is cooled as well, and WrappedSupra holds the fee
    ///      balances a UST's charge moves.
    function _coolRegistry(address _diamond) internal {
        vm.cool(_diamond);
        vm.cool(address(wsupra));
        address[] memory facets = IDiamondLoupe(_diamond).facetAddresses();
        for (uint256 i = 0; i < facets.length; i++) {
            vm.cool(facets[i]);
        }
    }

    /// @dev Measures a single processTasks batch's gas, with the registry cooled first
    ///      (_coolRegistry). processTasks checks msg.sender only (unlike monitorCycleEnd's
    ///      tx.origin check), so a single-arg prank is enough.
    function _measureProcessTasksBatch(
        address _diamond,
        uint64 _cycleIndex,
        uint64[] memory _indexes
    ) internal returns (uint256 gasUsed) {
        _coolRegistry(_diamond);
        vm.prank(LibUtils.VM_SIGNER);

        uint256 before = gasleft();
        ICoreFacet(_diamond).processTasks(_cycleIndex, _indexes);
        gasUsed = before - gasleft();
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
        require(_batchSize > 0, "batch size must be non-zero");
        uint256 numBatches = (_taskCount + _batchSize - 1) / _batchSize;
        uint256 remainder = _taskCount % _batchSize;
        batchGas = new uint256[](numBatches);
        batchTasks = new uint256[](numBatches);
        uint256 processed;
        for (uint256 b = 0; b < numBatches; b++) {
            uint256 count = _batchTaskCount(b, numBatches, _batchSize, remainder, _finalBatchFull);
            batchGas[b] = _measureProcessTasksBatch(_diamond, _cycleIndex, _buildRangeIndexes(processed, count));
            batchTasks[b] = count;
            _logBatch(_logPrefix, b, count, batchGas[b]);
            processed += count;
        }
    }

    /// @dev Number of tasks batch `_batch` of `_numBatches` carries: `_batchSize`, except the
    ///      batch that takes the `_remainder` (if non-zero), which is the first batch when
    ///      `_finalBatchFull` and the last otherwise. A separate function keeps _runBatches'
    ///      locals within the stack limit.
    function _batchTaskCount(
        uint256 _batch,
        uint256 _numBatches,
        uint256 _batchSize,
        uint256 _remainder,
        bool _finalBatchFull
    ) internal pure returns (uint256) {
        if (_remainder == 0) { return _batchSize; }
        bool remainderSlot = _finalBatchFull ? _batch == 0 : _batch == _numBatches - 1;
        return remainderSlot ? _remainder : _batchSize;
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

    /// @dev Gas one task can add to a record under `_diamond`'s record gas figures and
    ///      data-length caps, computed with the same LibCommon helpers
    ///      CoreFacet.getRecordMaxTaskCount uses.
    function _recordTaskGas(address _diamond) internal view returns (uint256) {
        (uint64 perTask, uint64 perStoredWord,,) = IConfigFacet(_diamond).getRecordGasParameters();
        (uint16 maxPayload, uint16 maxPredicate, uint16 maxAuxData, uint16 maxAuxEntries) =
            IConfigFacet(_diamond).getDataLengthCaps();
        return LibCommon.recordTaskGas(
            perTask, perStoredWord, LibCommon.recordStoredWords(maxPayload, maxPredicate, maxAuxData, maxAuxEntries)
        );
    }

    /// @dev Checks the measured batches against the record gas figures
    ///      (IConfigFacet.getRecordGasParameters, Entropy-Foundation/smr-moonshot#4755).
    ///      CoreFacet.getRecordMaxTaskCount gives every record k tasks at _recordTaskGas each
    ///      plus the finalization reserve, capacity * recordFinalizationGasPerTask, since the
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
        uint256 taskGas = _recordTaskGas(_diamond);
        uint256 reserve = _finalizationReserve(_diamond);
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

    /// @dev The finalization reserve every record carries under `_diamond`'s figures and active
    ///      capacity.
    function _finalizationReserve(address _diamond) internal view returns (uint256) {
        (,, uint64 finalizationPerTask,) = IConfigFacet(_diamond).getRecordGasParameters();
        return _capacity(_diamond) * uint256(finalizationPerTask);
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
            string.concat("Scenario 1: FINISHED->STARTED, N=", vm.toString(totalTasks), ", all survive"),
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
        (uint16 maxPayload, uint16 maxPredicate,,) = IConfigFacet(diamond).getDataLengthCaps();
        bytes memory payload = _payloadOfLength(maxPayload);
        bytes memory predicate = _predicateOfLength(diamond, maxPredicate);
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
    ///      batch of tasks. Every batch, with the intrinsic and calldata gas the gasleft()
    ///      bracket does not see, must fit `_cap`, the gas limit the node gives each record.
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
            (uint16 maxPayload, uint16 maxPredicate,,) = IConfigFacet(diamond).getDataLengthCaps();
            bytes memory payload = _payloadOfLength(maxPayload);
            bytes memory predicate = _predicateOfLength(diamond, maxPredicate);
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
