// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AppStorage, LibAppStorage, RegistryState, TaskMetadata, TaskMetadataLW} from "./LibAppStorage.sol";
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

    /// @notice Struct representing a removed task due to predicate failure.
    struct RemovedTask {
        uint64 taskIndex;
        TaskType taskType;
        address owner;
        bytes32 txHash;
        string reason;
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
    error InvalidTaskCapacity();
    error InvalidCycleDuration();
    error InvalidSysTaskDuration();
    error InvalidSysRegistryMaxGasCap();
    error InvalidSysTaskCapacity();
    error TaskDoesNotExist();
    error TaskIndexNotFound();

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: INTERNAL FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function to validate the registry configuration parameters.
    function validateConfigParameters(
        uint64 _taskDurationCapSecs,
        uint128 _registryMaxGasCap,
        uint8 _congestionThresholdPercentage,
        uint8 _congestionExponent,
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

    /// @notice Projects a stored task into its lightweight, accounting-relevant view.
    /// @dev Reads only the scalar fields — never touches the payloadTx/predicate/auxData
    /// storage slots, unlike a full `TaskMetadata memory` assignment.
    function toLW(TaskMetadata storage _task) internal view returns (TaskMetadataLW memory task) {
        task = TaskMetadataLW({
            maxGasAmount: _task.maxGasAmount,
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
    /// @param _removeFromSysReg Wheather to remove from system task registry.
    /// @param _removeFromActive Wheather to remove from active task list.
    function removeTask(uint64 _taskIndex, address _owner, bool _removeFromSysReg, bool _removeFromActive) internal {
        RegistryState storage registryState = LibAppStorage.registryState();

        if (_removeFromSysReg) {
            require(registryState.sysTaskIds.remove(_taskIndex), TaskIndexNotFound());
        }

        delete registryState.tasks[_taskIndex];
        require(registryState.taskIdList.remove(_taskIndex), TaskIndexNotFound());
        require(registryState.addressToTasks[_owner].remove(_taskIndex), TaskIndexNotFound());

        if (_removeFromActive) {
            require(registryState.activeTaskIds.remove(_taskIndex), TaskIndexNotFound());
        }
    }
}
