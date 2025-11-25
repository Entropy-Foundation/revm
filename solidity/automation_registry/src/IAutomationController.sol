// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CommonUtils} from "./CommonUtils.sol";

interface IAutomationController {
    // Custom errors
    error CallerNotVM();
    error InconsistentTransitionState();
    error InvalidAddress();
    error InvalidInputCycleIndex();
    error InvalidRegistryState();
    error OutOfOrderTaskProcessingRequest(); 
    error TransferFailed();
    
    // view functions
    function getCycleState() external view returns(uint8);
    function getCycleInfo() external view returns(CommonUtils.CycleState, uint64, uint64);
    function getTransitionInfo() external view returns (uint64, uint128);
}
