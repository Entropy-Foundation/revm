// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {CommonUtils} from "./CommonUtils.sol";

interface IAutomationRegistry {
    // Custom errors
    error AddressAlreadyExists();
    error AddressDoesNotExist();
    error AutomationNotEnabled();
    error CallerNotController();
    error UnauthorizedAccount();
    error CycleTransitionInProgress();
    error TaskDoesNotExist();
    error UnsupportedTaskOperation();
    error AlreadyCancelled();
    error ErrorDepositRefund();
    error SystemTaskDoesNotExist();
    error TaskIndexesCannotBeEmpty();
    error RegisteredTaskInvalidType();
    error TaskIndexNotFound();
    error TaskIndexNotUnique();
    error FailedToCallTxHashPrecompile();
    error TxnHashLengthShouldBe32(uint64);

    // View functions
    function ifTaskExists(uint64 _taskIndex) external view returns (bool);
    function checkTaskType(uint64 _taskIndex, CommonUtils.TaskType _type) external view returns (bool);
    function getAllActiveTaskIds() external view returns (uint256[] memory);
    function getTaskDetails(uint64 _taskIndex) external view returns (CommonUtils.TaskDetails memory);
    function getTaskIdList() external view returns (uint256[] memory);
    function getTotalActiveTasks() external view returns (uint256);
    function totalTasks() external view returns (uint256);
    function getNextTaskIndex() external view returns (uint64);
    
    // State updating functions
    function removeTask(uint64 _taskIndex, bool _removeFromSysReg) external;
    function updateTaskState(uint64 _taskIndex, CommonUtils.TaskState _taskState) external;
    function updateTaskIds(CommonUtils.CycleState _state) external;
    function refundDepositAndDrop(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) external;

    function register(
        bytes memory _payloadTx,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint64 _priority,
        bytes[] memory _auxData
    ) external;
}
