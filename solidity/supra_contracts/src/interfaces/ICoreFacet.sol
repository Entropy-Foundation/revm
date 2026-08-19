// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibCommon} from "../libraries/LibCommon.sol";

interface ICoreFacet {
    // =============================================================
    //                          Events
    // =============================================================
    /// @notice Emitted when automation is enabled.
    event AutomationEnabled(bool indexed status);
    
    /// @notice Emitted when automation is disabled.
    event AutomationDisabled(bool indexed status);

    /// @notice Event emitted on cycle transition containing active task indexes for the new cycle.
    event ActiveTasks(uint256[] indexed taskIndexes);

    /// @notice Event emitted on cycle transition containing removed task indexes.
    event RemovedTasks(uint64[] indexed taskIndexes);

    /// @notice Emitted when the cycle state transitions.
    event AutomationCycleEvent(
        uint64 indexed index,
        LibCommon.CycleState indexed state,
        uint64 startTime,
        uint64 durationSecs,
        LibCommon.CycleState indexed oldState
    );

    /// @notice Emitted when an automation fee is charged for an automation task for the cycle.
    event TaskCycleFeeWithdraw(
        uint64 cycleIndex,
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 indexed fee
    );

    /// @notice Emitted when a task is removed as fee exceeds task's automation fee cap for the cycle.
    event TaskCancelledCapacitySurpassed(
        uint64 indexed taskIndex,
        address owner,
        uint128 indexed fee,
        uint128 indexed automationFeeCapForCycle,
        bytes32 registrationHash
    );

    /// @notice Emitted when a task is removed due to insufficient balance or allowance.
    event TaskCancelledInsufficentBalanceAllowance(
        uint64 indexed taskIndex,
        address owner,
        uint128 indexed fee,
        uint256 indexed balance,
        uint256 allowance,
        bytes32 registrationHash
    );

    /// @notice Emitted when tasks are removed by system due to various reasons.
    event TaskRemovedBySystem(LibCommon.RemovedTask indexed removedTask);

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
    function getCycleStateDetails() external view returns (LibCommon.CycleDetails memory);

    // =============================================================
    //                  State update functions
    // =============================================================
    function monitorCycleEnd() external;
    function processTasks(uint64 _cycleIndex, uint256[] memory _taskIndexes) external;
    function enableAutomation() external;
    function disableAutomation() external;
    function removeRegisteredTask(uint64 _cycleIndex, uint64 _taskIndex, string memory _reason) external;
}
