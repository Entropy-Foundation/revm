// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AppStorage, Config, DataLengthCaps, LibAppStorage, RecordSizingParameters, RegistryState, TaskMetadata, TaskMetadataLW} from "./LibAppStorage.sol";
import {LibEvmGasConfig} from "./LibEvmGasConfig.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

library LibCommon {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice Benchmark-derived gas figures from which `CoreFacet.getRecordMaxTaskCount` sizes a
    /// `processTasks` record (Entropy-Foundation/smr-moonshot#4755), with the owner-set
    /// `RecordSizingParameters`. They measure the transition code itself, so they are constants
    /// that change only with that code: a contract change that moves a cost re-runs
    /// `test/CycleTransitionGas.t.sol` and re-derives them in the same upgrade.
    /// @dev Inlined into every facet that sizes records (CoreFacet's view, ConfigFacet's
    ///      pre-checks), so an upgrade that changes them replaces both facets in one cut.
    ///      Derived from `test/CycleTransitionGas.t.sol` at a registry of
    ///      `RECORD_GAS_BENCHMARK_CAPACITY` (400) tasks. Each measured call runs as its own
    ///      transaction after the registrations, and its execution gas is taken before refunds,
    ///      which a record's gas limit has to cover. The test asserts every measured batch against
    ///      these values, at 400 tasks and at the production 200, so a contract change that raises
    ///      a cost above them fails the suite.
    ///      - Removing a task costs 210,590 gas with the fixture's 24 stored words (scenario 2) and
    ///        1,062,126 with the 192 words of the default data-length caps (scenario 4): 5,069 gas
    ///        per word, close to the cost of clearing a stored slot, on top of about 89,000.
    ///        Dropping a cap-size task above lowered caps also checks its stored lengths and
    ///        refunds its deposit, 1,067,171 (scenario 5), about 94,000 on top of its words.
    ///        Rounded up: RECORD_GAS_PER_STORED_WORD = 5,500 and RECORD_GAS_PER_TASK = 100,000,
    ///        1,156,000 for a task at the default caps' 192 words. A task with 64 one-byte
    ///        auxData entries, which `recordStoredWords` charges two words each, is dropped for
    ///        590,687 against the 947,000 its 154 words allow (scenario 6). A task that survives
    ///        costs about 44,000 (scenario 1). These costs do not depend on the registry's size.
    ///      - The batch finalizing a FINISHED -> STARTED transition costs 3,528,632 gas more than
    ///        its tasks at the average non-final rate, 8,821 per registered task (scenario 1 at 400
    ///        tasks; 8,188 at 200). The premium per task grows with the registry, so
    ///        RECORD_FINALIZATION_GAS_PER_TASK = 10,000 is measured to cover registries of up to
    ///        RECORD_GAS_BENCHMARK_CAPACITY tasks, which `RecordSizingParameters.maxCapacity`
    ///        enforces.
    ///      - MAX_RECORD_TASK_SUPPORT_PERCENTAGE = 80: the derived-size tests size records with it at
    ///        caps from 4M to the production cap and check every record, intrinsic gas and calldata
    ///        included, fits its gas limit. The owner may set a lower percentage, which only makes
    ///        records smaller.
    uint64 internal constant RECORD_GAS_PER_TASK = 100_000;
    uint64 internal constant RECORD_GAS_PER_STORED_WORD = 5_500;
    uint64 internal constant RECORD_FINALIZATION_GAS_PER_TASK = 10_000;
    /// Equal to the Move registry's `automation_registry::TASK_SUPPORT_FACTOR`.
    uint8 internal constant MAX_RECORD_TASK_SUPPORT_PERCENTAGE = 80;
    /// Registry capacity the gas figures above are measured at, and the default
    /// `RecordSizingParameters.maxCapacity`.
    uint32 internal constant RECORD_GAS_BENCHMARK_CAPACITY = 400;

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
    error InvalidRecordSizingParameters();
    error RecordBudgetTooSmall();
    error CapacityAboveRecordGasLimit();
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

    /// @notice Validates the owner-set parameters that size a `processTasks` record.
    /// @dev The percentage must be above zero, which would size every record to no task, and at
    ///      most `MAX_RECORD_TASK_SUPPORT_PERCENTAGE`, above which records would be larger than
    ///      the benchmark shows they can complete. `maxCapacity` must be non-zero; whether it
    ///      covers the registry's capacity is checked by the callers
    ///      (`requireRecordSizingFits`).
    function validateRecordSizingParameters(RecordSizingParameters memory _parameters) internal pure {
        if (
            _parameters.taskSupportPercentage == 0
                || _parameters.taskSupportPercentage > MAX_RECORD_TASK_SUPPORT_PERCENTAGE
                || _parameters.maxCapacity == 0
        ) {
            revert InvalidRecordSizingParameters();
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
    ) internal pure returns (uint32) {
        // At most 2,048 * 3 + 2 * 65,535 = 137,214 words, so the sum fits a uint32.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(
            _wordsOf(_maxPayloadLength) + _wordsOf(_maxPredicateLength) + _wordsOf(_maxAuxDataLength)
                + 2 * uint256(_maxAuxDataEntries)
        );
    }

    /// @notice Data-length caps with their stored-words bound (`DataLengthCaps.storedWords`).
    function newDataLengthCaps(
        uint16 _maxPayloadLength,
        uint16 _maxPredicateLength,
        uint16 _maxAuxDataLength,
        uint16 _maxAuxDataEntries
    ) internal pure returns (DataLengthCaps memory) {
        return DataLengthCaps({
            maxPayloadLength: _maxPayloadLength,
            maxPredicateLength: _maxPredicateLength,
            maxAuxDataLength: _maxAuxDataLength,
            maxAuxDataEntries: _maxAuxDataEntries,
            storedWords: recordStoredWords(_maxPayloadLength, _maxPredicateLength, _maxAuxDataLength, _maxAuxDataEntries)
        });
    }

    /// @notice Whether `_next` is lower than `_current` in any of the four caps, so that a task
    /// admitted under `_current` may be above `_next`.
    function lowersAnyDataLengthCap(DataLengthCaps memory _next, DataLengthCaps memory _current)
        internal
        pure
        returns (bool)
    {
        return _next.maxPayloadLength < _current.maxPayloadLength
            || _next.maxPredicateLength < _current.maxPredicateLength
            || _next.maxAuxDataLength < _current.maxAuxDataLength
            || _next.maxAuxDataEntries < _current.maxAuxDataEntries;
    }

    /// @notice Whether a payloadTx of `_length` bytes is above the payload cap in force.
    /// @dev With `predicateAboveCap`, `auxDataEntriesAboveCap` and `auxDataLengthAboveCap`, the
    ///      one statement of the data-length caps, applied both when a task registers
    ///      (LibRegistry) and when lower caps apply to tasks already registered
    ///      (LibCore.exceedsDataLengthCaps), so that a registered task is dropped exactly when
    ///      the registry would now refuse it.
    function payloadAboveCap(uint256 _length) internal view returns (bool) {
        return _length > LibAppStorage.activeDataLengthCaps().maxPayloadLength;
    }

    /// @notice Whether a predicate of `_length` bytes is above the predicate cap in force.
    function predicateAboveCap(uint256 _length) internal view returns (bool) {
        return _length > LibAppStorage.activeDataLengthCaps().maxPredicateLength;
    }

    /// @notice Whether `_entries` auxData entries are above the entry-count cap in force. Checked
    /// before the combined length, which then needs reading each entry.
    function auxDataEntriesAboveCap(uint256 _entries) internal view returns (bool) {
        return _entries > LibAppStorage.activeDataLengthCaps().maxAuxDataEntries;
    }

    /// @notice Whether auxData entries of `_totalLength` bytes combined are above the
    /// combined-length cap in force.
    function auxDataLengthAboveCap(uint256 _totalLength) internal view returns (bool) {
        return _totalLength > LibAppStorage.activeDataLengthCaps().maxAuxDataLength;
    }

    /// @dev Number of 32-byte words `_length` bytes occupy.
    function _wordsOf(uint16 _length) private pure returns (uint256) {
        return (uint256(_length) + 31) / 32;
    }

    /// @notice The largest stored-words bound the registry may size records with before the next
    /// transition finalizes: `taskStoredWordsBound`, or the bound of the buffered caps if they
    /// are larger, since applying them raises `taskStoredWordsBound` to their bound
    /// (`LibCore.applyPendingDataLengthCaps`). A change checked against it holds once the buffer
    /// applies.
    function largestStoredWords() internal view returns (uint32 words) {
        AppStorage storage s = LibAppStorage.appStorage();
        words = s.taskStoredWordsBound;
        if (s.ifDataLengthCapsBufferExists) {
            uint32 bufferedWords = LibAppStorage.bufferDataLengthCaps().storedWords;
            if (bufferedWords > words) { words = bufferedWords; }
        }
    }

    /// @notice Gas one task can add to a `processTasks` call: a fixed part plus a part per word
    /// the task may store, since removing a task clears its storage.
    function recordTaskGas(uint256 _storedWords) internal pure returns (uint256) {
        return uint256(RECORD_GAS_PER_TASK) + uint256(RECORD_GAS_PER_STORED_WORD) * _storedWords;
    }

    /// @notice Number of tasks the registry can hold under `_config`: user plus system capacity.
    function recordCapacity(Config storage _config) internal view returns (uint256) {
        return uint256(_config.taskCapacity) + uint256(_config.sysTaskCapacity);
    }

    /// @notice The capacity in force once the buffers apply at the next cycle boundary: the
    /// buffered config's if one exists, otherwise the active one.
    function nextRecordCapacity() internal view returns (uint256) {
        if (LibAppStorage.appStorage().ifBufferExists) {
            return recordCapacity(LibAppStorage.bufferConfig());
        }
        return recordCapacity(LibAppStorage.activeConfig());
    }

    /// @notice The record sizing parameters in force once the buffers apply at the next cycle
    /// boundary: the buffered ones if they exist, otherwise the active ones.
    function nextRecordSizingParameters() internal view returns (RecordSizingParameters memory) {
        if (LibAppStorage.appStorage().ifRecordSizingParametersBufferExists) {
            return LibAppStorage.bufferRecordSizingParameters();
        }
        return LibAppStorage.activeRecordSizingParameters();
    }

    /// @notice Number of tasks one `processTasks` record with gas limit `_recordGasLimit` may carry.
    /// @dev The budget is `_taskSupportPercentage` percent of the gas limit. The finalizing record
    ///      pays `_capacity * RECORD_FINALIZATION_GAS_PER_TASK` on top of its tasks, and the node
    ///      cannot know in advance which record that is, so every record reserves it. The
    ///      remainder divided by the gas one task can add (`recordTaskGas`) is the count; 0 when
    ///      the reserve leaves no room for a task, which means no record at this gas limit can
    ///      finalize a transition of a registry of this capacity. Arithmetic is in uint256: with
    ///      `_capacity` a sum of two uint16 capacities, as `recordCapacity` returns, no product can
    ///      overflow.
    /// @param _recordGasLimit Gas limit the record is built with.
    /// @param _taskSupportPercentage `RecordSizingParameters.taskSupportPercentage`. Reverts with
    ///        `InvalidRecordSizingParameters` if it is zero, as when it was never set, or above
    ///        `MAX_RECORD_TASK_SUPPORT_PERCENTAGE`, the same range
    ///        `validateRecordSizingParameters` enforces when it is stored, so a value written by
    ///        any other path cannot size records larger than the benchmark supports.
    /// @param _storedWords Stored-words bound of the registry's tasks (`taskStoredWordsBound`).
    /// @param _capacity Number of tasks the registry can hold (`recordCapacity`).
    function recordMaxTaskCount(
        uint64 _recordGasLimit,
        uint8 _taskSupportPercentage,
        uint256 _storedWords,
        uint256 _capacity
    ) internal pure returns (uint64) {
        if (_taskSupportPercentage == 0 || _taskSupportPercentage > MAX_RECORD_TASK_SUPPORT_PERCENTAGE) {
            revert InvalidRecordSizingParameters();
        }
        uint256 budget = uint256(_recordGasLimit) * uint256(_taskSupportPercentage) / 100;
        uint256 finalizationReserve = _capacity * uint256(RECORD_FINALIZATION_GAS_PER_TASK);
        if (budget <= finalizationReserve) { return 0; }
        // The quotient is at most budget, which is below 2^64 since _recordGasLimit is a uint64
        // and the percentage is at most 80.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64((budget - finalizationReserve) / recordTaskGas(_storedWords));
    }

    /// @notice Reverts unless records can be sized for the given parameters, stored-words bound
    /// and registry capacity: with `CapacityAboveRecordGasLimit` if the capacity exceeds
    /// `_parameters.maxCapacity`, the largest the gas figures were measured for, and with
    /// `RecordBudgetTooSmall` unless a record at the current per-transaction gas cap carries at
    /// least one task.
    /// @dev Called by each of the owner's setters that the record size depends on
    ///      (`ConfigFacet.updateConfigBuffer`, `updateDataLengthCaps`,
    ///      `updateRecordSizingParameters`), with its own new value and the values the other two
    ///      will hold once the buffers apply at the next cycle boundary (`nextRecordCapacity`,
    ///      `nextRecordSizingParameters`, `largestStoredWords`). All three buffers apply together
    ///      and a buffer only changes what is in force when it applies, so the combination in force
    ///      after the boundary has been checked whatever order the setters were called in. The
    ///      per-transaction cap itself is governed in the gas schedule and can fall later;
    ///      `CoreFacet.getRecordMaxTaskCount` then returns 0 and the node pauses automation. Not
    ///      called from `DiamondInit`: the registry is initialised before the gas config
    ///      precompile serves a value, both at genesis and in the test fixtures.
    function requireRecordSizingFits(
        RecordSizingParameters memory _parameters,
        uint256 _storedWords,
        uint256 _capacity
    ) internal view {
        if (_capacity > _parameters.maxCapacity) { revert CapacityAboveRecordGasLimit(); }
        uint64 count = recordMaxTaskCount(
            LibEvmGasConfig.txGasLimitCap(), _parameters.taskSupportPercentage, _storedWords, _capacity
        );
        if (count == 0) { revert RecordBudgetTooSmall(); }
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
