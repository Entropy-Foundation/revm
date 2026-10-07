// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibCommon} from "../libraries/LibCommon.sol";
import {TaskMetadata} from "../libraries/LibAppStorage.sol";

interface IRegistryViewFacet {
    // =============================================================
    //                      View functions
    // =============================================================
    function ifTaskExists(uint64 _taskIndex) external view  returns (bool);
    function ifSysTaskExists(uint64 _taskIndex) external view returns (bool);
    function getActiveTaskIds() external view returns (uint64[] memory);
    function getCycleLockedFees() external view returns (uint256);
    function getGasCommittedForCurrentCycle() external view returns (uint128);
    function getGasCommittedForNextCycle() external view returns (uint128);
    function getNextCycleRegistryMaxGasCap() external view returns (uint128);
    function getNextCycleSysRegistryMaxGasCap() external view returns (uint128);
    function getNextTaskIndex() external view returns (uint64);
    function getSystemGasCommittedForCurrentCycle() external view returns (uint128);
    function getSystemGasCommittedForNextCycle() external view returns (uint128);
    function getSystemTaskIds() external view returns (uint256[] memory);
    function getTaskDetails(uint64 _taskIndex) external view returns (TaskMetadata memory);
    function getTaskDetailsBulk(uint64[] memory _taskIndexes) external view returns (TaskMetadata[] memory);
    function getTaskIdList() external view returns (uint256[] memory);
    function getTaskOwner(uint64 _taskIndex) external view returns (address);
    function getTotalActiveTasks() external view returns (uint256);
    function getTotalDepositedAutomationFees() external view returns (uint256);
    function getTotalLockedBalance() external view returns (uint256);
    function getTasksByAddress(address _addr) external view returns (uint256[] memory);
    function hasActiveSystemTask(address _account, uint64 _taskIndex) external view returns (bool);
    function hasActiveTaskOfType(address _account, uint64 _taskIndex, LibCommon.TaskType _type) external view returns (bool);
    function hasActiveUserTask(address _account, uint64 _taskIndex) external view returns (bool);
    function totalSystemTasks() external view returns (uint256);
    function totalTasks() external view returns (uint256);
}
