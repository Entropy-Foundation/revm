// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CommonUtils} from "./CommonUtils.sol";
import {LibRegistry} from "./LibRegistry.sol";

interface IAutomationRegistry {
    // Custom errors
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
    error AlreadyEnabled();
    error AlreadyDisabled();
    error InvalidCycleDuration();
    error InvalidCongestionThreshold();
    error InvalidCongestionExponent();
    error InvalidSysTaskDuration();
    error InvalidRegistryMaxGasCap();
    error InvalidSysRegistryMaxGasCap();
    error InvalidTaskCapacity();
    error InvalidSysTaskCapacity();
    error UnacceptableRegistryMaxGasCap();    
    error UnacceptableSysRegistryMaxGasCap();
    error ColdWalletNotSet();
    error InsufficientBalance();
    error RequestExceedsLockedBalance();
    error CycleTransitionInProgress();
    error TaskDoesNotExist();
    error UnsupportedTaskOperation();
    error AlreadyCancelled();
    error ErrorDepositRefund();
    error GasCommittedValueUnderflow();
    error SystemTaskDoesNotExist();
    error TaskIndexesCannotBeEmpty();
    error ErrorCycleFeeRefund();
    error InsufficientBalanceForRefund();
    error UnauthorizedCaller();
    error RegisteredTaskInvalidType();
    error AutomationNotEnabled();

    // View functions
    function ifTaskExists(uint64 _taskIndex) external view returns (bool);
    function isUST(uint64 _taskIndex) external view returns (bool);
    function getAllActiveTaskIds() external view returns (uint256[] memory);
    function getCycleLockedFees() external view returns (uint256);
    function getGasCommittedForNextCycle() external view returns (uint128);
    function getRegistryMaxGasCap() external view returns (uint128);
    function getTaskDetails(uint64 _taskIndex) external view returns (CommonUtils.TaskDetails memory);
    function getTaskIdList() external view returns (uint256[] memory);
    function getTotalActiveTasks() external view returns (uint256);
    function totalTasks() external view returns (uint256);
    function ifConfigBufferExists() external view returns (bool);
    function getBufferCycleDurationSecs() external view returns (uint64);
    function getVM() external returns (address);
    function supraERC20() external view returns (address);
    function isAutomationEnabled() external view returns (bool);
    function calculateAutomationFeeMultiplierForCurrentCycleInternal() external view returns (uint128);
    function calculateAutomationFeeMultiplierForCommittedOccupancy(uint128 _totalCommittedMaxGas) external view returns (uint128);
    function calculateTaskFee(
        CommonUtils.TaskState _state,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _potentialFeeTimeframe,
        uint64 _currentTime,
        uint128 _automationFeePerSec,
        uint128 _registryMaxGasCap
    ) external view returns (uint128);
    function cycleDurationSecs() external view returns (uint64);

    
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
    function applyPendingConfig() external;
    function safeUnlockLockedDeposit(
        uint64 _taskIndex,
        uint128 _lockedDeposit
    ) external returns (bool);
    function refundDepositAndDrop(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) external;
    function refundTaskFees(
        uint64 _taskIndex,
        uint64 _currentTime,
        uint256 _cycleLockedFees
    ) external returns (uint256);
}
