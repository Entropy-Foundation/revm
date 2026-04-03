// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibCommon} from "./libraries/LibCommon.sol";
import {TaskMetadata} from "./libraries/LibAppStorage.sol";

interface SupraContractsBindings {

    // View functions of RegistryFacet
    function ifTaskExists(uint64 _taskIndex) external view returns (bool);
    function getActiveTaskIds() external view returns (uint256[] memory);
    function getTaskIdList() external view returns (uint256[] memory);
    function getTaskDetails(uint64 _taskIndex) external view returns (TaskMetadata memory);
    function getTaskDetailsBulk(uint64[] memory _taskIndexes) external view returns (TaskMetadata[] memory);

    // View functions of CoreFacet
    function isAutomationEnabled() external view returns (bool);
    function getCycleInfo() external view returns (uint64, uint64, uint64, LibCommon.CycleState);
    function getTransitionInfo() external view returns (uint64, uint128);

    // Entry function to be called by node runtime for bookkeeping
    function processTasks(uint64 _cycleIndex, uint64[] memory _taskIndexes) external;

    // Entry function of the BlockMeta for block metadata transaction
    function blockPrologue() external;

    // Emitted when the cycle state transitions.
    event AutomationCycleEvent(
        uint64 indexed index,
        LibCommon.CycleState indexed state,
        uint64 startTime,
        uint64 durationSecs,
        LibCommon.CycleState indexed oldState
    );
}
