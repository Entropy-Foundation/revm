// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AppStorage, Config, LibAppStorage, RegistryState, TaskMetadata, TaskMetadataLW} from "./LibAppStorage.sol";
import {LibEvmGasConfig} from "./LibEvmGasConfig.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

library LibCommon {
    using EnumerableSet for EnumerableSet.UintSet;

    struct CycleDetails {
        uint64 index;
        uint64 startTime;
        uint64 durationSecs;
        LibCommon.CycleState state;
        uint64 nextTaskIndexPosition;
        uint64[] expectedTasksToBeProcessed;
    }

    /// @notice Enum describing state of the cycle.
    enum CycleState {
        READY,
        STARTED,
        FINISHED,
        SUSPENDED
    }

    /// @notice Enum describing state of a task.
    enum TaskState {
        PENDING,
        ACTIVE,
        CANCELLED
    }

    /// @notice Enum describing task type.
    enum TaskType {
        UST,
        GST
    }

    /// @notice Why the VM signer asks the registry to remove a registered task.
    /// @dev ERROR: the task failed at runtime (malformed payload or predicate, failed predicate,
    ///      unexecutable gas amount). The owner is refunded half of the remaining current-cycle
    ///      fee and the whole deposit (half the deposit for a PENDING task), see
    ///      {LibAccounting.unlockDepositAndCycleFee}.
    ///      CONFIG_UPDATE: a governed configuration the task depends on changed at an epoch
    ///      boundary (#4327). Today that is an EVM gas figure served by {LibEvmGasConfig}: the
    ///      task's transaction can no longer be admitted (its
    ///      maxGasAmount is above the per-transaction gas cap, or, for a UST, its gasPriceCap is
    ///      below the minimum gas price). The registry re-checks the task against the current
    ///      figures, and the owner is refunded the whole remaining current-cycle fee and the whole
    ///      deposit (#4087).
    enum TaskRemovalReason {
        ERROR,
        CONFIG_UPDATE
    }

    /// @notice Represents intermediate state of the registry on cycle change.
    struct IntermediateStateOfCycleChange {
        uint256 cycleLockedFees;
        uint128 gasCommittedForNextCycle;
        uint128 sysGasCommittedForNextCycle;
        uint64[] removedTasks;
    }

    /// @notice Struct representing transition result.
    struct TransitionResult {
        uint128 fees;
        uint128 gas;
        uint128 sysGas;
        bool isRemoved;
    }
    
    /// @notice Struct representing a cancelled task.
    struct TaskCancelled{
        uint64 taskIndex;
        TaskType taskType;
        bytes32 txHash;
    }
        
    /// @notice Struct representing a stopped task.
    struct TaskStopped {
        uint64 taskIndex;
        uint128 depositRefund;
        uint128 cycleFeeRefund;
        bytes32 txHash;
    }

    /// @notice Struct representing an entry in access list.
    struct AccessListEntry {
        address addr;
        bytes32[] storageKeys;
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ERRORS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    error InvalidTaskDuration();
    error InvalidRegistryMaxGasCap();
    error InvalidCongestionThreshold();
    error InvalidCongestionExponent();
    error InvalidMaxCongestionExponent();
    error CongestionExponentExceedsMax();
    error InvalidTaskCapacity();
    error InvalidCycleDuration();
    error InvalidSysTaskDuration();
    error InvalidSysRegistryMaxGasCap();
    error InvalidSysTaskCapacity();
    error PayloadLengthCapNotWordAligned();
    error PredicateLengthCapNotWordAligned();
    error InvalidRecordGasParameters();
    error RecordBudgetTooSmall();
    error ChangeDuringTransition();
    error TaskDoesNotExist();
    error TaskIndexNotFound();

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: INTERNAL FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Validates the payload and predicate length caps for task registration.
    /// @dev Registration admits a payloadTx or predicate only if its length is a multiple of 32
    ///      bytes, the length of an ABI encoding (LibRegistry.validateInputs, validatePredicate).
    ///      A cap that is not a multiple of 32 is never reached exactly: the largest admitted input
    ///      is the cap rounded down to a multiple of 32. Each cap is therefore required to be a
    ///      multiple of 32, so the stored cap is the largest admitted length. The auxData cap is not
    ///      constrained, since auxData entries are not required to be ABI-encoded.
    function validateDataLengthCaps(uint16 _maxPayloadLength, uint16 _maxPredicateLength) internal pure {
        if (_maxPayloadLength % 32 != 0) { revert PayloadLengthCapNotWordAligned(); }
        if (_maxPredicateLength % 32 != 0) { revert PredicateLengthCapNotWordAligned(); }
    }

    /// @notice Validates the parameters that size a `processTasks` record.
    /// @dev Each gas figure scales a term of the record cost in `recordMaxTaskCount`: a zero
    ///      `_recordGasPerTask` or `_recordGasPerStoredWord` would understate every task, and a
    ///      zero `_recordFinalizationGasPerTask` would ignore the finalization cost.
    ///      `_recordTaskSupportPercentage` is the share of the gas limit budgeted for tasks, so it
    ///      must lie in 1..100: 0 would size every record to no task, and above 100 would budget
    ///      more gas than the record has.
    function validateRecordGasParameters(
        uint64 _recordGasPerTask,
        uint64 _recordGasPerStoredWord,
        uint64 _recordFinalizationGasPerTask,
        uint8 _recordTaskSupportPercentage
    ) internal pure {
        if (_recordGasPerTask == 0 || _recordGasPerStoredWord == 0 || _recordFinalizationGasPerTask == 0) {
            revert InvalidRecordGasParameters();
        }
        if (_recordTaskSupportPercentage == 0 || _recordTaskSupportPercentage > 100) {
            revert InvalidRecordGasParameters();
        }
    }

    /// @notice Upper bound on the storage words one task's payload, predicate and auxData occupy
    /// under the given data-length caps.
    /// @dev Each byte array takes one word per 32 bytes of content; payload and predicate caps are
    ///      multiples of 32 (`validateDataLengthCaps`). Each auxData entry is its own byte array,
    ///      so on top of the combined length it can take a length word and a partly filled word,
    ///      two words per entry. Removing a task clears all of them (`removeTask`).
    function recordStoredWords(
        uint16 _maxPayloadLength,
        uint16 _maxPredicateLength,
        uint16 _maxAuxDataLength,
        uint16 _maxAuxDataEntries
    ) internal pure returns (uint256) {
        return _wordsOf(_maxPayloadLength) + _wordsOf(_maxPredicateLength) + _wordsOf(_maxAuxDataLength)
            + 2 * uint256(_maxAuxDataEntries);
    }

    /// @dev Number of 32-byte words `_length` bytes occupy.
    function _wordsOf(uint16 _length) private pure returns (uint256) {
        return (uint256(_length) + 31) / 32;
    }

    /// @notice Gas one task can add to a `processTasks` call: a fixed part plus a part per word
    /// the task may store, since removing a task clears its storage.
    function recordTaskGas(
        uint64 _recordGasPerTask,
        uint64 _recordGasPerStoredWord,
        uint256 _storedWords
    ) internal pure returns (uint256) {
        return uint256(_recordGasPerTask) + uint256(_recordGasPerStoredWord) * _storedWords;
    }

    /// @notice `recordTaskGas` for the stored figures and the current data-length caps.
    function currentRecordTaskGas() internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.appStorage();
        return recordTaskGas(
            s.recordGasPerTask,
            s.recordGasPerStoredWord,
            recordStoredWords(s.maxPayloadLength, s.maxPredicateLength, s.maxAuxDataLength, s.maxAuxDataEntries)
        );
    }

    /// @notice Number of tasks the registry can hold under `_config`: user plus system capacity.
    function recordCapacity(Config storage _config) internal view returns (uint256) {
        return uint256(_config.taskCapacity) + uint256(_config.sysTaskCapacity);
    }

    /// @notice The larger of the active capacity and, if a config is buffered, the buffered one:
    /// the capacity a change applied now must hold for, before and after the buffer applies.
    function largestRecordCapacity() internal view returns (uint256 capacity) {
        capacity = recordCapacity(LibAppStorage.activeConfig());
        if (LibAppStorage.appStorage().ifBufferExists) {
            uint256 bufferedCapacity = recordCapacity(LibAppStorage.bufferConfig());
            if (bufferedCapacity > capacity) { capacity = bufferedCapacity; }
        }
    }

    /// @notice Number of tasks one `processTasks` record with gas limit `_recordGasLimit` may carry.
    /// @dev The budget is `_recordTaskSupportPercentage` percent of the gas limit. The finalizing
    ///      record pays `_capacity * _recordFinalizationGasPerTask` on top of its tasks, and the
    ///      node cannot know in advance which record that is, so every record reserves it. The
    ///      remainder divided by `_taskGas` is the count; 0 when the reserve leaves no room for a
    ///      task, which means no record at this gas limit can finalize a transition of a registry
    ///      of this capacity. Arithmetic is in uint256: with `_capacity` a sum of two uint16
    ///      capacities, as `recordCapacity` returns, no product can overflow.
    /// @param _recordGasLimit Gas limit the record is built with.
    /// @param _taskGas Gas one task can add to the record (`recordTaskGas`). Reverts with
    ///        `InvalidRecordGasParameters` if zero, as it is when the figures were never set.
    /// @param _recordFinalizationGasPerTask Finalization gas per task the registry can hold.
    /// @param _capacity Number of tasks the registry can hold (`recordCapacity`).
    /// @param _recordTaskSupportPercentage Share, in percent, of the gas limit budgeted for tasks
    ///        (`AppStorage.recordTaskSupportPercentage`). Reverts with
    ///        `InvalidRecordGasParameters` if zero or above 100, as zero is when it was never set.
    function recordMaxTaskCount(
        uint64 _recordGasLimit,
        uint256 _taskGas,
        uint64 _recordFinalizationGasPerTask,
        uint256 _capacity,
        uint8 _recordTaskSupportPercentage
    ) internal pure returns (uint64) {
        if (_taskGas == 0) { revert InvalidRecordGasParameters(); }
        if (_recordTaskSupportPercentage == 0 || _recordTaskSupportPercentage > 100) {
            revert InvalidRecordGasParameters();
        }
        uint256 budget = uint256(_recordGasLimit) * uint256(_recordTaskSupportPercentage) / 100;
        uint256 finalizationReserve = _capacity * uint256(_recordFinalizationGasPerTask);
        if (budget <= finalizationReserve) { return 0; }
        // The quotient is at most budget, which is below 2^64 since _recordGasLimit is a uint64
        // and the percentage is at most 100.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64((budget - finalizationReserve) / _taskGas);
    }

    /// @notice Reverts with `RecordBudgetTooSmall` unless a record at the current per-transaction
    /// gas cap carries at least one task, for the given task gas, finalization figure, registry
    /// capacity and task-support percentage.
    /// @dev Called when the owner changes the record gas figures, the data-length caps or the
    ///      capacity, so that none of these changes leaves the registry with records that cannot
    ///      carry a task at the cap in force. The cap itself is governed in the gas schedule and
    ///      can fall later; `CoreFacet.getRecordMaxTaskCount` then returns 0 and the node pauses
    ///      automation. Not called from `DiamondInit`: the registry is initialised before the gas
    ///      config precompile serves a value, both at genesis and in the test fixtures.
    function requireRecordBudgetFits(
        uint256 _taskGas,
        uint64 _recordFinalizationGasPerTask,
        uint256 _capacity,
        uint8 _recordTaskSupportPercentage
    ) internal view {
        uint64 count = recordMaxTaskCount(
            LibEvmGasConfig.txGasLimitCap(),
            _taskGas,
            _recordFinalizationGasPerTask,
            _capacity,
            _recordTaskSupportPercentage
        );
        if (count == 0) { revert RecordBudgetTooSmall(); }
    }

    /// @notice Reverts with `ChangeDuringTransition` unless the cycle is READY or STARTED.
    /// @dev Guards the setters that change `CoreFacet.getRecordMaxTaskCount` with immediate
    ///      effect (`ConfigFacet.updateRecordGasParameters`, `ConfigFacet.updateDataLengthCaps`).
    ///      The node sizes a transition's records when the transition starts and again only at
    ///      an epoch change, so during a transition (FINISHED or SUSPENDED) the count the records
    ///      were built with must stay the registry's count (Entropy-Foundation/smr-moonshot#4755).
    ///      A buffered capacity needs no guard: `monitorCycleEnd` applies it before the node
    ///      sizes the transition's records, and the suspension path applies it with the final
    ///      batch.
    function requireNoCycleTransition() internal view {
        LibCommon.CycleState state = LibAppStorage.appStorage().cycleState;
        if (state != LibCommon.CycleState.READY && state != LibCommon.CycleState.STARTED) {
            revert ChangeDuringTransition();
        }
    }

    /// @notice Helper function to validate the registry configuration parameters.
    function validateConfigParameters(
        uint64 _taskDurationCapSecs,
        uint128 _registryMaxGasCap,
        uint8 _congestionThresholdPercentage,
        uint8 _congestionExponent,
        uint8 _maxCongestionExponent,
        uint16 _taskCapacity,
        uint64 _cycleDurationSecs,
        uint64 _sysTaskDurationCapSecs,
        uint128 _sysRegistryMaxGasCap,
        uint16 _sysTaskCapacity
    ) internal pure {
        if (_taskDurationCapSecs <= _cycleDurationSecs) { revert InvalidTaskDuration(); }
        if (_registryMaxGasCap == 0) { revert InvalidRegistryMaxGasCap(); }
        if (_congestionThresholdPercentage > 100) { revert InvalidCongestionThreshold(); }
        if (_congestionExponent == 0) { revert InvalidCongestionExponent(); }
        if (_maxCongestionExponent == 0) { revert InvalidMaxCongestionExponent(); }
        if (_congestionExponent > _maxCongestionExponent) { revert CongestionExponentExceedsMax(); }
        if (_taskCapacity == 0) { revert InvalidTaskCapacity(); }
        if (_cycleDurationSecs == 0) { revert InvalidCycleDuration(); }
        if (_sysTaskDurationCapSecs <= _cycleDurationSecs) { revert InvalidSysTaskDuration(); }
        if (_sysRegistryMaxGasCap == 0) { revert InvalidSysRegistryMaxGasCap(); }
        if (_sysTaskCapacity == 0) { revert InvalidSysTaskCapacity(); }
    }

    /// @notice Checks whether cycle is in STARTED state.
    function isCycleStarted() internal view returns (bool) {
        AppStorage storage s = LibAppStorage.appStorage();
        return s.cycleState == LibCommon.CycleState.STARTED;
    }
    
    /// @notice Returns the cycle end time.
    function getCycleEndTime() internal view returns (uint64 cycleEndTime) {
        AppStorage storage s = LibAppStorage.appStorage();
        cycleEndTime = s.startTime + s.durationSecs;
    }
    
    /// @notice Checks if a task exist.
    /// @param _taskIndex Task index to check if a task exists against it.
    function ifTaskExists(uint64 _taskIndex) internal view returns (bool) {
        RegistryState storage registryState = LibAppStorage.registryState();
        return registryState.tasks[_taskIndex].owner != address(0) && registryState.taskIdList.contains(_taskIndex);
    }

    /// @notice Returns the details of a task. Reverts if task doesn't exist.
    /// @param _taskIndex Task index to get details for.
    function getTask(uint64 _taskIndex) internal view returns (TaskMetadata storage task) {
        if (!ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }
        task = LibAppStorage.registryState().tasks[_taskIndex];
    }

    /// @notice Removes `_value` from a plain uint64[] by linear scan + swap-and-pop.
    /// @dev activeTaskIds is a plain array (see LibAppStorage.RegistryState), not an
    ///      EnumerableSet, because nothing reads it via contains() and it's rebuilt
    ///      wholesale each cycle from TransitionState.survivedTaskIds (see
    ///      LibCore.updateRegistryState) — so it doesn't need an O(1)-membership index.
    ///      This makes a single removal O(k) (k = current length) instead of
    ///      EnumerableSet's O(1); order doesn't matter here (unlike taskIdList), so
    ///      swap-and-pop is safe. Bounded by taskCapacity+sysTaskCapacity, the
    ///      governance-owned system-wide task cap (see ConfigFacet.updateConfigBuffer).
    /// @return found True if `_value` was present and removed.
    function removeFromActiveTaskIds(uint64[] storage _arr, uint64 _value) private returns (bool found) {
        uint256 len = _arr.length;
        for (uint256 i = 0; i < len; i++) {
            if (_arr[i] == _value) {
                _arr[i] = _arr[len - 1];
                _arr.pop();
                return true;
            }
        }
        return false;
    }

    /// @notice Projects a stored task into its lightweight, accounting-relevant view.
    /// @dev Reads only the scalar fields — never touches the payloadTx/predicate/auxData
    /// storage slots, unlike a full `TaskMetadata memory` assignment.
    function toLW(TaskMetadata storage _task) internal view returns (TaskMetadataLW memory task) {
        task = TaskMetadataLW({
            maxGasAmount: _task.maxGasAmount,
            gasPriceCap: _task.gasPriceCap,
            automationFeeCapForCycle: _task.automationFeeCapForCycle,
            depositFee: _task.depositFee,
            txHash: _task.txHash,
            taskIndex: _task.taskIndex,
            expiryTime: _task.expiryTime,
            owner: _task.owner,
            taskType: _task.taskType,
            taskState: _task.taskState
        });
    }

    /// @notice Returns the lightweight details of a task. Reverts if task doesn't exist.
    /// @param _taskIndex Task index to get details for.
    function getTaskLW(uint64 _taskIndex) internal view returns (TaskMetadataLW memory task) {
        if (!ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }
        task = toLW(LibAppStorage.registryState().tasks[_taskIndex]);
    }

    /// @notice Function to remove a task from the registry.
    /// @param _taskIndex Index of the task to remove.
    /// @param _owner Address of the task owner.
    /// @param _removeFromSysReg Whether to remove from system task registry.
    /// @param _removeFromActive Whether to remove from active task list.
    function removeTask(uint64 _taskIndex, address _owner, bool _removeFromSysReg, bool _removeFromActive) internal {
        RegistryState storage registryState = LibAppStorage.registryState();

        if (_removeFromSysReg) {
            require(registryState.sysTaskIds.remove(_taskIndex), TaskIndexNotFound());
        }

        delete registryState.tasks[_taskIndex];
        require(registryState.taskIdList.remove(_taskIndex), TaskIndexNotFound());
        require(registryState.addressToTasks[_owner].remove(_taskIndex), TaskIndexNotFound());

        if (_removeFromActive) {
            require(removeFromActiveTaskIds(registryState.activeTaskIds, _taskIndex), TaskIndexNotFound());
        }
    }
}
