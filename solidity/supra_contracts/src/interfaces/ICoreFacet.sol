// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibCommon} from "../libraries/LibCommon.sol";

interface ICoreFacet {
    // =============================================================
    //                          Events
    // =============================================================
    // Struct, array, string and bytes parameters, and amounts, are carried in the log data, not
    // indexed. script/check_event_indexing.sh states the rule; the forge-tests CI job runs it
    // after forge build and fails on an indexed struct, array, string or bytes parameter (#4285).

    /// @notice Emitted when automation is enabled.
    event AutomationEnabled(bool indexed status);
    
    /// @notice Emitted when automation is disabled.
    event AutomationDisabled(bool indexed status);

    /// @notice Event emitted on cycle transition containing active task indexes for the new cycle.
    /// @dev cycleIndex is topic 1 and is the index of the new cycle. taskIndexes is ABI-encoded
    ///      in the log data as uint64[] and is the registry's activeTaskIds for that cycle. It is
    ///      emitted once, by the processTasks call that finalizes a FINISHED -> STARTED
    ///      transition, and only when at least one task is active.
    event ActiveTasks(uint64 indexed cycleIndex, uint64[] taskIndexes);

    /// @notice Event emitted on cycle transition containing removed task indexes.
    /// @dev cycleIndex is topic 1 and is the cycle index processTasks was called with: for a
    ///      FINISHED -> STARTED transition the cycle being entered, the same index ActiveTasks
    ///      carries for that transition, and for a suspension the cycle being suspended.
    ///      taskIndexes is ABI-encoded in the log data. It is emitted by each processTasks call
    ///      that removed at least one task, and lists the tasks that call removed, so a
    ///      transition processed in several batches emits several RemovedTasks logs with the
    ///      same cycleIndex; the transition's removals are the union of their lists.
    event RemovedTasks(uint64 indexed cycleIndex, uint64[] taskIndexes);

    /// @notice Emitted when the cycle state transitions.
    event AutomationCycleEvent(
        uint64 indexed index,
        LibCommon.CycleState indexed state,
        uint64 startTime,
        uint64 durationSecs,
        LibCommon.CycleState indexed oldState
    );

    /// @notice Emitted when an automation fee is charged for an automation task for the cycle.
    /// @dev cycleIndex, taskIndex and owner are topics 1, 2 and 3; fee is in the log data.
    ///      cycleIndex is the cycle the fee pays for: the cycle a FINISHED -> STARTED
    ///      transition enters, the same index ActiveTasks and RemovedTasks carry for it.
    event TaskCycleFeeWithdraw(
        uint64 indexed cycleIndex,
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 fee
    );

    /// @notice Emitted when a task is removed as fee exceeds task's automation fee cap for the cycle.
    /// @dev taskIndex and owner are topics 1 and 2; fee, automationFeeCapForCycle and
    ///      registrationHash are in the log data.
    event TaskCancelledCapacitySurpassed(
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 fee,
        uint128 automationFeeCapForCycle,
        bytes32 registrationHash
    );

    /// @notice Emitted when a task is removed due to insufficient balance or allowance.
    /// @dev taskIndex and owner are topics 1 and 2; fee, balance, allowance and
    ///      registrationHash are in the log data.
    event TaskCancelledInsufficientBalanceAllowance(
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 fee,
        uint256 balance,
        uint256 allowance,
        bytes32 registrationHash
    );

    /// @notice Emitted when the VM signer removes a task for a runtime error (TaskRemovalReason.ERROR).
    /// @dev taskIndex and owner are topics 1 and 2, so a reader filters system removals by task
    ///      or by owner; each appears only there. taskType, txHash, reason and details are
    ///      ABI-encoded in the log data, details being the VM signer's description of the reason.
    event TaskRemovedBySystem(
        uint64 indexed taskIndex,
        address indexed owner,
        LibCommon.TaskType taskType,
        bytes32 txHash,
        LibCommon.TaskRemovalReason reason,
        string details
    );

    /// @notice Emitted when a task is removed because the EVM gas config of the executing block's
    /// epoch no longer admits its transaction: its maxGasAmount is above txGasLimitCap, or it is a
    /// UST whose gasPriceCap is below minGasPrice (#4087).
    /// @dev Emitted on a TaskRemovalReason.GAS_CONFIG_UPDATE removal during the cycle, with
    /// cycleFeeRefund the task's whole fee for the remaining cycle time, and when processTasks
    /// drops the task at a cycle transition, with cycleFeeRefund 0: the ended cycle's fee was
    /// earned and the new cycle's fee has not been charged. depositRefund is the whole deposit of
    /// a UST and 0 for a GST, which pays none; at a cycle transition it is 0 if the deposit could
    /// not be transferred, which an ErrorUnlockTaskDepositFee or ErrorInsufficientBalanceToRefund
    /// event then records.
    event TaskRemovedByGasConfigUpdate(
        uint64 indexed taskIndex,
        address indexed owner,
        LibCommon.TaskType indexed taskType,
        uint128 maxGasAmount,
        uint128 gasPriceCap,
        uint64 txGasLimitCap,
        uint256 minGasPrice,
        uint128 cycleFeeRefund,
        uint128 depositRefund,
        bytes32 txHash
    );

    // =============================================================
    //                      Custom errors
    // =============================================================
    error AlreadyDisabled();
    error AlreadyEnabled();
    error InconsistentTransitionState();
    error InsufficientBalanceForRefund();
    error InvalidArrayLength();
    error InvalidInputCycleIndex();
    error InvalidOperationForCurrentCycleState();
    error InvalidRegistryState();
    error OutOfOrderTaskProcessingRequest();
    error RegisteredTaskInvalidType();
    error TaskIndexNotFound();
    error TransferFailed();
    error UnknownTaskToProcess(uint64 taskIndex);

    // =============================================================
    //                      View functions
    // =============================================================
    function getCycleInfo() external view returns (uint64, uint64, uint64, LibCommon.CycleState);
    function getCycleDuration() external view returns (uint64);
    function getTransitionInfo() external view returns (uint64, uint128);
    function isAutomationEnabled() external view returns (bool);
    function isAutomationReadyEnabled() external view returns (bool);
    function getCycleStateDetails() external view returns (LibCommon.CycleDetails memory);

    // =============================================================
    //                  State update functions
    // =============================================================
    function monitorCycleEnd() external;
    function processTasks(uint64 _cycleIndex, uint64[] memory _taskIndexes) external;
    function enableAutomation() external;
    function disableAutomation() external;
    function removeRegisteredTask(
        uint64 _cycleIndex,
        uint64 _taskIndex,
        LibCommon.TaskRemovalReason _reason,
        string memory _details
    ) external;
}
