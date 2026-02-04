// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {CommonUtils} from "./CommonUtils.sol";

interface IAutomationCore {
    // Custom errors
    error AddressCannotBeZero();
    error AutomationNotEnabled();
    error CallerNotController();
    error CallerNotRegistry();
    error CycleTransitionInProgress();
    error ErrorDepositRefund();
    error ErrorCycleFeeRefund();
    error InvalidAmount();
    error InvalidMaxGasAmount();
    error InvalidTaskType();
    error InvalidTxHash();
    error AlreadyEnabled();
    error AlreadyDisabled();
    error GasCommittedExceedsMaxGasCap();
    error GasCommittedValueUnderflow();
    error InsufficientBalance();
    error InsufficientFeeCapForCycle();
    error InvalidCongestionExponent();
    error InvalidCongestionThreshold();
    error InvalidCycleDuration();
    error InvalidExpiryTime();
    error InvalidGasPriceCap();
    error InvalidRegistryMaxGasCap();
    error InvalidSysRegistryMaxGasCap();
    error InvalidSysTaskCapacity();
    error InvalidSysTaskDuration();
    error InvalidTaskCapacity();
    error InvalidTaskDuration();
    error RegistrationDisabled();
    error RequestExceedsLockedBalance();
    error TaskCapacityReached();
    error TaskExpiresBeforeNextCycle();
    error TransferFailed();
    error UnacceptableRegistryMaxGasCap();    
    error UnacceptableSysRegistryMaxGasCap();
    error UnauthorizedCaller();

    // View functions
    function flatRegistrationFeeWei() external view returns (uint128);
    function getAutomationController() external view returns (address);
    function erc20Supra() external view returns (address);
    function calculateTaskFee(
        CommonUtils.TaskState _state,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _potentialFeeTimeframe,
        uint64 _currentTime,
        uint128 _automationFeePerSec
    ) external view returns (uint128);
    function calculateAutomationFeeMultiplierForCurrentCycleInternal() external view returns (uint128);
    function calculateAutomationFeeMultiplierForCommittedOccupancy(uint128 _totalCommittedMaxGas) external view returns (uint128);
    function cycleDurationSecs() external view returns (uint64);
    function getVmSigner() external view returns (address);
    function getGasCommittedForNextCycle() external view returns (uint128);
    function getCycleLockedFees() external view returns (uint256);
    function getTotalDepositedAutomationFees() external view returns (uint256);
    function updateStateForValidRegistration(
        uint256 _totalTasks, 
        uint8 _inputType,
        uint64 _regTime,
        uint64 _expiryTime,
        CommonUtils.TaskType _taskType,
        bytes memory _payloadTx, 
        uint128 _maxGasAmount, 
        bytes32 _txHash,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle
    ) external;

    // State updating functions
    function applyPendingConfig() external returns (bool, uint64);
    function incTotalDepositedAutomationFees(uint256 _totalDepositedAutomationFees) external;
    function chargeFees(address _from, uint256 _amount) external;
    function safeUnlockLockedDeposit(
        uint64 _taskIndex,
        uint128 _lockedDeposit
    ) external returns (bool);
    function refundTaskFees(
        uint64 _currentTime,
        uint64 _refundDuration, 
        uint128 _automationFeePerSec,
        CommonUtils.TaskDetails memory _task
    ) external;
     function safeDepositRefund(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) external returns (bool);
    function refund(address _to, uint128 _amount) external;
    function unlockDepositAndCycleFee(
        uint64 _taskIndex,
        CommonUtils.TaskState _taskState,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _residualInterval,
        uint64 _currentTime,
        uint128 _lockedFeeForNextCycle
    )  external returns (uint128, uint128);
    function updateGasCommittedForNextCycle(CommonUtils.TaskType _taskType, uint128 _maxGasAmount) external;
    function updateGasCommittedAndCycleLockedFees(
        uint256 _lockedFees,
        uint128 _sysGasCommittedForNextCycle,
        uint128 _gasCommittedForNextCycle,
        uint128 _gasCommittedForNewCycle
    ) external;
}