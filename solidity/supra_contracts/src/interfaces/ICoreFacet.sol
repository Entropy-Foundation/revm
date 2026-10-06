// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibCommon} from "../libraries/LibCommon.sol";

interface ICoreFacet {
    // =============================================================
    //                          Events
    // =============================================================
    // A struct or array parameter of an event is not declared indexed: an indexed parameter of
    // such a type is logged as the keccak256 of its ABI encoding, which carries none of its
    // fields. The value is ABI-encoded in the log data instead, where a reader decodes it with
    // the event's ABI (Entropy-Foundation/smr-moonshot#4285). Indexing is reserved for the
    // value-typed parameters a reader filters on, such as a task index or an owner; a fee, refund
    // or balance amount is not filtered on and is placed in the log data. Indexing is not part of
    // the event signature, so it does not affect topic0.

    /// @notice Emitted when automation is enabled.
    event AutomationEnabled(bool indexed status);
    
    /// @notice Emitted when automation is disabled.
    event AutomationDisabled(bool indexed status);

    /// @notice Event emitted on cycle transition containing active task indexes for the new cycle.
    /// @dev The log has no indexed parameter. taskIndexes is ABI-encoded in the log data and is
    ///      the registry's activeTaskIds for the new cycle. It is emitted once, by the
    ///      processTasks call that finalizes a FINISHED -> STARTED transition, and only when at
    ///      least one task is active.
    event ActiveTasks(uint256[] taskIndexes);

    /// @notice Event emitted on cycle transition containing removed task indexes.
    /// @dev The log has no indexed parameter. taskIndexes is ABI-encoded in the log data. It is
    ///      emitted by each processTasks call that removed at least one task, and lists the tasks
    ///      that call removed. In the call that finalizes a FINISHED -> STARTED transition it is
    ///      emitted after ActiveTasks and any AutomationCycleEvent of that call, and its entries
    ///      are removals from the transition into the cycle that ActiveTasks lists.
    event RemovedTasks(uint64[] taskIndexes);

    /// @notice Emitted when the cycle state transitions.
    event AutomationCycleEvent(
        uint64 indexed index,
        LibCommon.CycleState indexed state,
        uint64 startTime,
        uint64 durationSecs,
        LibCommon.CycleState indexed oldState
    );

    /// @notice Emitted when an automation fee is charged for an automation task for the cycle.
    /// @dev taskIndex and owner are topics 1 and 2; cycleIndex and fee are in the log data.
    event TaskCycleFeeWithdraw(
        uint64 cycleIndex,
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 fee
    );

    /// @notice Emitted when a task is removed as fee exceeds task's automation fee cap for the cycle.
    /// @dev taskIndex is topic 1; owner, fee, automationFeeCapForCycle and registrationHash
    ///      are in the log data.
    event TaskCancelledCapacitySurpassed(
        uint64 indexed taskIndex,
        address owner,
        uint128 fee,
        uint128 automationFeeCapForCycle,
        bytes32 registrationHash
    );

    /// @notice Emitted when a task is removed due to insufficient balance or allowance.
    /// @dev taskIndex is topic 1; owner, fee, balance, allowance and registrationHash are in
    ///      the log data.
    event TaskCancelledInsufficientBalanceAllowance(
        uint64 indexed taskIndex,
        address owner,
        uint128 fee,
        uint256 balance,
        uint256 allowance,
        bytes32 registrationHash
    );

    /// @notice Emitted when the VM signer removes a task for a runtime error (TaskRemovalReason.ERROR).
    /// @dev The log has no indexed parameter. removedTask is ABI-encoded in the log data as
    ///      (uint64 taskIndex, TaskType taskType, address owner, bytes32 txHash,
    ///      TaskRemovalReason reason, string details), details being the VM signer's description
    ///      of the reason.
    event TaskRemovedBySystem(LibCommon.RemovedTask removedTask);

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
    function processTasks(uint64 _cycleIndex, uint256[] memory _taskIndexes) external;
    function enableAutomation() external;
    function disableAutomation() external;
    function removeRegisteredTask(
        uint64 _cycleIndex,
        uint64 _taskIndex,
        LibCommon.TaskRemovalReason _reason,
        string memory _details
    ) external;
}
