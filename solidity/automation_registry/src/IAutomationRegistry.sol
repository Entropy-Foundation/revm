// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AutomationStorage} from "./AutomationStorage.sol";

interface IAutomationRegistry {
    // custom errors
    error AddressAlreadyExists();
    error AddressDoesNotExist();
    error CallerNotController();
    error CycleNotStarted();
    error GasCommittedExceedsMaxGasCap();
    error InsufficientFeeCapForCycle();
    error InsufficentValueSent();
    error InvalidAddress();
    error InvalidAuxDataLength();
    error InvalidExpiryTime();
    error InvalidGasPriceCap();
    error InvalidMaxGasAmount();
    error InvalidTaskDuration();
    error InvalidTxHash();
    error InvalidTaskType();
    error InvalidTaskTypeLength();
    error InvalidTypeForTask();
    error RegistrationDisabled();
    error TaskCapacityReached();
    error TaskExpiresBeforeNextCycle();
    error TransferFailed();
    error UnauthorizedAccount();

    // view functions
    function isAuthorizedSubmitter(address _account) external view returns (bool);
    function ifTaskExists(uint64 _taskIndex) external view returns (bool);
    function isUST(uint64 _taskIndex) external view returns (bool);
    function getNextTaskIndex() external view returns (uint64);
    function getGasCommittedForNextCycle() external view returns (uint128);
    function getGasCommittedForCurrentCycle() external view returns (uint128);
    function getRegistryMaxGasCap() external view returns (uint128);
    function getTaskDetails(uint64 _taskIndex) external view returns (AutomationStorage.TaskMetadata memory);
    function getTaskOwner(uint64 _taskIndex) external view returns (address);
    function getTotalDepositedAutomationFees() external view returns (uint256);
    function totalSystemTasks() external view returns (uint256);
    function totalUserTasks() external view returns (uint16);

    function calculateAutomationFeeForInterval(
        uint64 _duration,
        uint128 _taskOccupancy,
        uint128 _automationFeePerSec,
        uint128 _registryMaxGasCap
    ) external pure returns (uint128);

    // state update functions
    function removeSysTask(uint64 _taskIndex) external;
    function removeTask(uint64 _taskIndex) external;
    function updateTotalDepositedAutomationFees(uint256 _updatedValue) external;
    function updateTaskState(uint64 _taskIndex, AutomationStorage.TaskState _taskState) external;
}
