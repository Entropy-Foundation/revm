// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {LibUtils} from "../libraries/LibUtils.sol";
import {TaskMetadata} from "../libraries/LibAppStorage.sol";

interface IRegistryFacet {
    // Custom errors
    error AlreadyCancelled();
    error AutomationNotEnabled();
    error CycleTransitionInProgress();
    error ErrorDepositRefund();
    error FailedToCallTxHashPrecompile();
    error SystemTaskDoesNotExist();
    error TaskDoesNotExist();
    error TaskIndexesCannotBeEmpty();
    error TaskIndexNotFound();
    error TaskIndexNotUnique();
    error TxnHashLengthShouldBe32(uint64);
    error UnauthorizedAccount();
    error UnsupportedTaskOperation();

    // View functions
    function calculateAutomationFeeMultiplierForCommittedOccupancy(uint128 _totalCommittedMaxGas) external view returns (uint128);
    function calculateAutomationFeeMultiplierForCurrentCycle() external view returns (uint128);
    function estimateAutomationFee(uint128 _taskOccupancy) external view returns (uint128);
    function estimateAutomationFeeWithCommittedOccupancy(uint128 _taskOccupancy, uint128 _committedOccupancy) external view returns (uint128);
    function isAuthorizedSubmitter(address _account) external view returns (bool);
    function ifTaskExists(uint64 _taskIndex) external view  returns (bool);
    function ifSysTaskExists(uint64 _taskIndex) external view returns (bool);
    function getActiveTaskIds() external view returns (uint256[] memory);
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
    function getTaskIds() external view returns (uint256[] memory);
    function getTaskOwner(uint64 _taskIndex) external view returns (address);
    function getTotalActiveTasks() external view returns (uint256);
    function getTotalDepositedAutomationFees() external view returns (uint256);
    function getTotalLockedBalance() external view returns (uint256);
    function getUserTasks(address _user) external view returns (uint256[] memory);
    function hasActiveSystemTask(address _account, uint64 _taskIndex) external view returns (bool);
    function hasActiveTaskOfType(address _account, uint64 _taskIndex, LibUtils.TaskType _type) external view returns (bool);
    function hasActiveUserTask(address _account, uint64 _taskIndex) external view returns (bool);
    function totalSystemTasks() external view returns (uint256);
    function totalTasks() external view returns (uint256);
}
