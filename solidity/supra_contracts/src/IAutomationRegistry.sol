// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {CommonUtils} from "./CommonUtils.sol";

interface IAutomationRegistry {
    // Custom errors
    error AddressAlreadyExists();
    error AddressDoesNotExist();
    error CallerNotController();
    error UnauthorizedAccount();
    error CycleTransitionInProgress();
    error TaskDoesNotExist();
    error UnsupportedTaskOperation();
    error AlreadyCancelled();
    error ErrorDepositRefund();
    error GasCommittedValueUnderflow();
    error SystemTaskDoesNotExist();
    error TaskIndexesCannotBeEmpty();
    error InsufficientBalanceForRefund();
    error RegisteredTaskInvalidType();
    error AutomationNotEnabled();
    error TaskIndexNotFound();
    error TaskIndexNotUnique();

    // View functions
    function ifTaskExists(uint64 _taskIndex) external view returns (bool);
    function checkTaskType(uint64 _taskIndex, CommonUtils.TaskType _type) external view returns (bool);
    function getAllActiveTaskIds() external view returns (uint256[] memory);
    function getCycleLockedFees() external view returns (uint256);
    function getGasCommittedForNextCycle() external view returns (uint128);
    function getSystemGasCommittedForNextCycle() external view returns (uint128);
    function getTaskDetails(uint64 _taskIndex) external view returns (CommonUtils.TaskDetails memory);
    function getTaskIdList() external view returns (uint256[] memory);
    function getTotalActiveTasks() external view returns (uint256);
    function totalTasks() external view returns (uint256);
    function getGasCommittedForCurrentCycle() external view returns (uint128);
    
    // State updating functions
    function removeTask(uint64 _taskIndex, bool _removeFromSysReg) external;
    function updateTaskState(uint64 _taskIndex, CommonUtils.TaskState _taskState) external;
    function updateRegistryState(
        uint128 _sysGasCommittedForNextCycle,
        uint128 _gasCommittedForNextCycle,
        uint128 _gasCommittedForNewCycle,
        uint256 _lockedFees,
        uint8 _state
    ) external;
    function refundDepositAndDrop(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) external;
}
