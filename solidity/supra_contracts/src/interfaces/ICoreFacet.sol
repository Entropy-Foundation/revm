// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

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
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 fee
    );

    /// @notice Emitted when a task is removed as fee exceeds task's automation fee cap for the cycle.
    event TaskCancelledCapacitySurpassed(
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 fee,
        uint128 automationFeeCapForCycle,
        bytes32 registrationHash
    );

    /// @notice Emitted when a task is removed due to insufficient balance.
    event TaskCancelledInsufficentBalance(
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 fee,
        uint256 balance,
        bytes32 registrationHash
    );


    // =============================================================
    //                      Custom errors
    // =============================================================
    error AlreadyDisabled();
    error AlreadyEnabled();
    error CallerNotVmSigner();
    error InvalidRegistryState();

    // =============================================================
    //                      View functions
    // =============================================================
    function getCycleInfo() external view returns (uint64, uint64, uint64, LibCommon.CycleState);
    function getCycleDuration() external view returns (uint64);
    function getTransitionInfo() external view returns (uint64, uint128);
    function isAutomationEnabled() external view returns (bool);

    // =============================================================
    //                  State update functions
    // =============================================================
    function monitorCycleEnd() external;
    function processTasks(uint64 _cycleIndex, uint64[] memory _taskIndexes) external;
    function enableAutomation() external;
    function disableAutomation() external;
}
