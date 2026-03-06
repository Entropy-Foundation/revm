// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {CommonUtils} from "./CommonUtils.sol";

interface SupraContractsBindings {

    // View functions of AutomationRegistry
    function getAllActiveTaskIds() external view returns (uint256[] memory);
    function getTaskIdList() external view returns (uint256[] memory);
    function getTaskDetails(uint64 _taskIndex) external view returns (CommonUtils.TaskDetails memory);
    function getTaskDetailsBulk(uint64[] memory _taskIndexes) external view returns (CommonUtils.TaskDetails[] memory);

    // View functions of AutomationController
    function getCycleStateDetails() external view returns (CommonUtils.CycleDetails memory details);
    function isAutomationEnabled() external view returns (bool);

    // Entry function to be called by node runtime for bookkeeping
    function processTasks(uint64 _cycleIndex, uint64[] memory _taskIndexes) external;

    // Entry function of the BlockMeta for block metadata transaction
    function blockPrologue() external;

    // Emitted when the cycle state transitions.
    event AutomationCycleEvent(
        uint64 indexed index,
        CommonUtils.CycleState indexed state,
        uint64 startTime,
        uint64 durationSecs,
        CommonUtils.CycleState indexed oldState
    );
}
