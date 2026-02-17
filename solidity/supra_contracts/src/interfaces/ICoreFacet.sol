// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {LibUtils} from "../libraries/LibUtils.sol";

interface ICoreFacet {
    // Custom errors
    error AlreadyDisabled();
    error AlreadyEnabled();
    error CallerNotVmSigner();
    error InvalidRegistryState();

    // View functions
    function getCycleInfo() external view returns (uint64, uint64, uint64, LibUtils.CycleState);
    function getCycleDuration() external view returns (uint64);
    function getTransitionInfo() external view returns (uint64, uint128);
    function isAutomationEnabled() external view returns (bool);

    // State update functions
    function monitorCycleEnd() external;
}
