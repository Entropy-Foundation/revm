// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {CommonUtils} from "./CommonUtils.sol";

interface SupraContractsBindings {

    // View functions of AutomationRegistry
    function ifTaskExists(uint64 _taskIndex) external view returns (bool);
    function getAllActiveTaskIds() external view returns (uint256[] memory);
    function getTaskIdList() external view returns (uint256[] memory);
    function isAutomationEnabled() external view returns (bool);

    function getTaskDetails(uint64 _taskIndex) external view returns (CommonUtils.TaskDetails memory);
    function getTaskDetailsBulk(uint64[] memory _taskIndexes) external view returns (CommonUtils.TaskDetails[] memory);

    // View functions of AutomationController
    function getCycleInfo() external view returns(uint64, uint64, uint64, CommonUtils.CycleState);
    function getTransitionInfo() external view returns (uint64, uint128);

    // Entry function to be called by node runtime for bookkeeping
    function processTasks(uint64 _cycleIndex, uint64[] memory _taskIndexes) external;

    // Entry function of the BlockMeta for block metadata transaction
    function blockPrologue() external;
}
