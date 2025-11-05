// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IAutomationController {
    // custom errors
    error InconsistentTransitionState();
    error InvalidInputCycleIndex();
    error InvalidRegistryState();
    error OutOfOrderTaskProcessingRequest(); 
    error TaskDoesNotExist();
    error TaskIndexesCannotBeEmpty();
    error TransferFailed();

    // read functions
    function getCycleState() external view returns(uint8);
    function getCycleInfo() external view returns(uint64, uint64);
}
