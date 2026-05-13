// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibCommon} from "./libraries/LibCommon.sol";
import {TaskMetadata} from "./libraries/LibAppStorage.sol";

interface SupraContractsBindings {

    // View function of Automation Registry Diamond
    function isInitialized() external view returns (bool);

    // View functions of RegistryFacet
    function ifTaskExists(uint64 _taskIndex) external view returns (bool);
    function getActiveTaskIds() external view returns (uint256[] memory);
    function getTaskIdList() external view returns (uint256[] memory);
    function getTaskDetails(uint64 _taskIndex) external view returns (TaskMetadata memory);
    function getTaskDetailsBulk(uint64[] memory _taskIndexes) external view returns (TaskMetadata[] memory);

    // View functions of CoreFacet
    function isAutomationEnabled() external view returns (bool);
    function getCycleStateDetails() external view returns (LibCommon.CycleDetails memory);

    // Entry function to be called by node runtime for bookkeeping
    function processTasks(uint64 _cycleIndex, uint256[] memory _taskIndexes) external;

    // Entry function to be called by node runtime to remove tasks with fatal errors
    function removeRegisteredTask(uint64 _cycleIndex, uint64 _taskIndex, string memory _reason) external;

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
