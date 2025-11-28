// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CommonUtils} from "./CommonUtils.sol";

interface IAutomationController {
    // Custom errors
    error AddressCannotBeEOA();
    error CallerNotBlockMeta();
    error CallerNotVM();
    error InconsistentTransitionState();
    error AddressCannotBeZero();
    error InvalidInputCycleIndex();
    error InvalidRegistryState();
    error OutOfOrderTaskProcessingRequest(); 
    error TransferFailed();
    
    // View functions
    function getCycleState() external view returns(uint8);
    function getCycleInfo() external view returns(CommonUtils.CycleState, uint64, uint64);
    function getTransitionInfo() external view returns (uint64, uint128);

    // State updating functions
    function monitorCycleEnd() external;
}
