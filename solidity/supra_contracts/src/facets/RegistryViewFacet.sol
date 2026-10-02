// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibAppStorage, RegistryState, TaskMetadata} from "../libraries/LibAppStorage.sol";
import {LibCommon} from "../libraries/LibCommon.sol";
import {IRegistryViewFacet} from "../interfaces/IRegistryViewFacet.sol";
import {IFacetSelectors} from "../interfaces/IFacetSelectors.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Read-only view onto the automation registry's state.
/// @dev Split out of RegistryFacet (Entropy-Foundation/smr-moonshot#4101) to keep
/// RegistryFacet's deployed bytecode clear of EIP-170's 24,576-byte limit: any future fix
/// to RegistryFacet, or to a library it inlines, redeploys a fresh RegistryFacet
/// (Entropy-Foundation/smr-moonshot#2772), and that redeployment must also fit the limit.
/// The four fee-estimating views and `isAuthorizedSubmitter` stay on RegistryFacet instead
/// of moving here: `register` already inlines the same `LibAccounting` fee math, so moving
/// the fee views would duplicate it across both facets, and `registerSystemTask` calls
/// `isAuthorizedSubmitter` directly.
contract RegistryViewFacet is IRegistryViewFacet, IFacetSelectors {
    using EnumerableSet for *;

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Returns all the automation tasks available in the registry.
    /// @dev Node's off-chain automation registry manager relies on existence of it.
    /// Update/Replace is acceptable,  but removal should be checked against node-runtime first.
    function getTaskIdList() external view returns (uint256[] memory) {
        return LibAppStorage.registryState().taskIdList.values();
    }

    /// @notice Returns all the automation tasks registered by an address.
    /// @param _addr Address to fetch registered tasks for.
    function getTasksByAddress(address _addr) external view returns (uint256[] memory) {
        return LibAppStorage.registryState().addressToTasks[_addr].values();
    }

    /// @notice Returns all the system tasks available in the registry.
    function getSystemTaskIds() external view returns (uint256[] memory) {
        return LibAppStorage.registryState().sysTaskIds.values();
    }

    /// @notice Returns the owner of the task
    /// @param _taskIndex Task index of the task to query.
    function getTaskOwner(uint64 _taskIndex) external view returns (address) {
        return LibAppStorage.registryState().tasks[_taskIndex].owner;
    }

    /// @notice Returns the next task index.
    function getNextTaskIndex() external view returns (uint64) {
        return LibAppStorage.registryState().currentIndex;
    }

    /// @notice Returns the number of total tasks.
    function totalTasks() external view returns (uint256) {
        return LibAppStorage.registryState().taskIdList.length();
    }

    /// @notice Returns the number of total system tasks.
    function totalSystemTasks() external view returns (uint256) {
        return LibAppStorage.registryState().sysTaskIds.length();
    }

    /// @notice Returns if a task exists in the registry.
    /// @param _taskIndex Task index to check existence for.
    function ifTaskExists(uint64 _taskIndex) external view  returns (bool) {
        return LibCommon.ifTaskExists(_taskIndex);
    }

    /// @notice Returns if a system task exists in the registry.
    /// @param _taskIndex Task index of the system task to check existence for.
    function ifSysTaskExists(uint64 _taskIndex) external view returns (bool) {
        return LibAppStorage.registryState().sysTaskIds.contains(_taskIndex);
    }

    /// @notice Returns the details of a task. Reverts if task doesn't exist.
    /// @dev Node's off-chain automation registry manager relies on existence of it.
    /// Update/Replace is acceptable,  but removal should be checked against node-runtime first.
    function getTaskDetails(uint64 _taskIndex) external view returns (TaskMetadata memory) {
        return LibCommon.getTask(_taskIndex);
    }

    /// @notice Retrieves the details of automation tasks by their task index. Skips a task if it doesn't exist.
    /// @param _taskIndexes Input task indexes to get details of.
    /// @return Task details of the tasks that exist.
    function getTaskDetailsBulk(uint64[] memory _taskIndexes) external view returns (TaskMetadata[] memory) {
        uint256 count = _taskIndexes.length;
        TaskMetadata[] memory temp =  new TaskMetadata[](count);
        uint256 exists;

        for (uint256 i = 0; i < count; i++) {
            if (LibCommon.ifTaskExists(_taskIndexes[i])) {
                temp[exists] = LibAppStorage.registryState().tasks[_taskIndexes[i]];
                exists += 1;
            }
        }

        TaskMetadata[] memory taskDetails =  new TaskMetadata[](exists);
        for (uint256 i = 0; i < exists; i++) {
            taskDetails[i] = temp[i];
        }
        return taskDetails;
    }

    /// @notice Returns the total number of active tasks.
    function getTotalActiveTasks() external view returns (uint256) {
        return LibAppStorage.registryState().activeTaskIds.length;
    }

    /// @notice Returns all the active task indexes.
    /// @dev Node's off-chain automation registry manager relies on existence of it.
    /// Update/Replace is acceptable,  but removal should be checked against node-runtime first.
    function getActiveTaskIds() external view returns (uint256[] memory) {
        return LibAppStorage.registryState().activeTaskIds;
    }

    /// @notice Checks whether there is an active task in registry with specified input task index.
    function hasActiveUserTask(address _account, uint64 _taskIndex) external view returns (bool) {
        return hasActiveTaskOfType(_account, _taskIndex, LibCommon.TaskType.UST);
    }

    /// @notice Checks whether there is an active system task in registry with specified input task index.
    function hasActiveSystemTask(address _account, uint64 _taskIndex) external view returns (bool) {
        return hasActiveTaskOfType(_account, _taskIndex, LibCommon.TaskType.GST);
    }

    /// @notice Checks whether there is an active task in registry with specified input task index of the input type.
    /// The type can be either 0 for user submitted tasks, and 1 for governance authorized tasks.
    function hasActiveTaskOfType(address _account, uint64 _taskIndex, LibCommon.TaskType _type) public view returns (bool) {
        TaskMetadata storage task = LibAppStorage.registryState().tasks[_taskIndex];
        return task.owner == _account && task.taskState != LibCommon.TaskState.PENDING && task.taskType == _type;
    }

    /// @notice Returns the gas committed for the next cycle.
    function getGasCommittedForNextCycle() external view returns (uint128) {
        return LibAppStorage.registryState().gasCommittedForNextCycle;
    }

    /// @notice Returns the gas committed for the current cycle.
    function getGasCommittedForCurrentCycle() external view returns (uint128) {
        return LibAppStorage.registryState().gasCommittedForThisCycle;
    }

    /// @notice Returns the system gas committed for the next cycle.
    function getSystemGasCommittedForNextCycle() external view returns (uint128) {
        return LibAppStorage.registryState().sysGasCommittedForNextCycle;
    }

    /// @notice Returns the system gas committed for the current cycle.
    function getSystemGasCommittedForCurrentCycle() external view returns (uint128) {
        return LibAppStorage.registryState().sysGasCommittedForThisCycle;
    }

    /// @notice Returns the registry max gas cap for the next cycle.
    function getNextCycleRegistryMaxGasCap() external view returns (uint128) {
        return LibAppStorage.registryState().nextCycleRegistryMaxGasCap;
    }

    /// @notice Returns the system registry max gas cap for the next cycle.
    function getNextCycleSysRegistryMaxGasCap() external view returns (uint128) {
        return LibAppStorage.registryState().nextCycleSysRegistryMaxGasCap;
    }

    /// @notice Returns the locked fees for the cycle.
    function getCycleLockedFees() external view returns (uint256) {
        return LibAppStorage.registryState().cycleLockedFees;
    }

    /// @notice Returns the total amount of automation fees deposited.
    function getTotalDepositedAutomationFees() external view returns (uint256) {
        return LibAppStorage.registryState().totalDepositedAutomationFees;
    }

    /// @notice Returns the total amount locked which comprises of 'cycleLockedFees' and 'totalDepositedAutomationFees'.
    function getTotalLockedBalance() external view returns (uint256) {
        RegistryState storage registryState = LibAppStorage.registryState();
        return registryState.cycleLockedFees + registryState.totalDepositedAutomationFees;
    }

    function getSelectors() external pure override returns (bytes4[] memory selectors) {
        selectors = new bytes4[](25);
        selectors[0]  = RegistryViewFacet.getTaskIdList.selector;
        selectors[1]  = RegistryViewFacet.getSystemTaskIds.selector;
        selectors[2]  = RegistryViewFacet.getTaskOwner.selector;
        selectors[3]  = RegistryViewFacet.getNextTaskIndex.selector;
        selectors[4]  = RegistryViewFacet.totalTasks.selector;
        selectors[5]  = RegistryViewFacet.totalSystemTasks.selector;
        selectors[6]  = RegistryViewFacet.getTaskDetails.selector;
        selectors[7]  = RegistryViewFacet.getTaskDetailsBulk.selector;
        selectors[8]  = RegistryViewFacet.getTotalActiveTasks.selector;
        selectors[9]  = RegistryViewFacet.getActiveTaskIds.selector;
        selectors[10] = this.hasActiveUserTask.selector;
        selectors[11] = this.hasActiveSystemTask.selector;
        selectors[12] = this.hasActiveTaskOfType.selector;
        selectors[13] = RegistryViewFacet.getGasCommittedForNextCycle.selector;
        selectors[14] = RegistryViewFacet.getGasCommittedForCurrentCycle.selector;
        selectors[15] = RegistryViewFacet.getSystemGasCommittedForNextCycle.selector;
        selectors[16] = RegistryViewFacet.getSystemGasCommittedForCurrentCycle.selector;
        selectors[17] = RegistryViewFacet.getNextCycleRegistryMaxGasCap.selector;
        selectors[18] = RegistryViewFacet.getNextCycleSysRegistryMaxGasCap.selector;
        selectors[19] = RegistryViewFacet.getCycleLockedFees.selector;
        selectors[20] = RegistryViewFacet.getTotalDepositedAutomationFees.selector;
        selectors[21] = RegistryViewFacet.getTotalLockedBalance.selector;
        selectors[22] = RegistryViewFacet.ifTaskExists.selector;
        selectors[23] = RegistryViewFacet.ifSysTaskExists.selector;
        selectors[24] = RegistryViewFacet.getTasksByAddress.selector;
    }
}
