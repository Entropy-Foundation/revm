// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {CommonUtils} from "./CommonUtils.sol";

interface IAutomationController {
    // Custom errors
    error AddressCannotBeEOA();
    error CallerNotBlockMeta();
    error CallerNotVM();
    error ConfigUpdateFailed();
    error InconsistentTransitionState();
    error AddressCannotBeZero();
    error InvalidInputCycleIndex();
    error InvalidRegistryState();
    error OutOfOrderTaskProcessingRequest(); 
    error RefundFailed();
    error RefundDepositAndDropFailed();
    error RemoveTaskFailed();
    error TransferFailed();    
    error UnlockLockedDepositFailed();
    error UpdateRegistryStateFailed();
    error UpdateTaskStateFailed();

    // View functions
    function getCycleInfo() external view returns(uint64, uint64, uint64, CommonUtils.CycleState);
    function getTransitionInfo() external view returns (uint64, uint128);

    // State updating functions
    function monitorCycleEnd() external;
}
