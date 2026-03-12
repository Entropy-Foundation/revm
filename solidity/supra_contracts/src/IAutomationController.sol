// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {CommonUtils} from "./CommonUtils.sol";

interface IAutomationController {
    // Custom errors
    error AlreadyEnabled();
    error AlreadyDisabled();
    error CallerNotVmSigner();
    error InconsistentTransitionState();
    error InvalidInputCycleIndex();
    error InvalidRegistryState();
    error OutOfOrderTaskProcessingRequest(); 
    error RefundFailed();
    error RefundDepositAndDropFailed();
    error RemoveTaskFailed();
    error TransferFailed();    
    error UnlockLockedDepositFailed();
    error UpdateGasCommittedAndCycleLockedFeesFailed();
    error UpdateTaskStateFailed();

    // View functions
    function getCycleInfo() external view returns (uint64, uint64, uint64, CommonUtils.CycleState);
    function getCycleDuration() external view returns (uint64);
    function getCycleEndTime() external view returns (uint64 cycleEndTime);
    function getTransitionInfo() external view returns (uint64, uint128);
    function isAutomationEnabled() external view returns (bool);
    function isCycleStarted() external view returns (bool);
    function isTransitionInProgress() external view returns (bool);

    // State updating functions
    function monitorCycleEnd() external;
}
