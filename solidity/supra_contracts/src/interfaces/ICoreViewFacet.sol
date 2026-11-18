// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibCommon} from "../libraries/LibCommon.sol";

/// @notice View functions over the automation registry's cycle state, served by CoreViewFacet.
/// @dev Entropy-Foundation/smr-moonshot#4989. Callers reach these functions by casting the
///      diamond to this interface; ICoreFacet declares CoreFacet's events, errors and
///      state-changing functions.
interface ICoreViewFacet {
    // =============================================================
    //                      View functions
    // =============================================================
    function getCycleInfo() external view returns (uint64, uint64, uint64, LibCommon.CycleState);
    function getCycleDuration() external view returns (uint64);
    function getTransitionInfo() external view returns (uint64, uint128);
    function isAutomationEnabled() external view returns (bool);
    function isAutomationReadyEnabled() external view returns (bool);
    function getCycleStateDetails() external view returns (LibCommon.CycleDetails memory);
    function getRecordMaxTaskCount(uint64 _recordGasLimit) external view returns (uint64);
}
