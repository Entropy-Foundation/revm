// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AppStorage, LibAppStorage, RegistryState, TaskMetadata} from "../libraries/LibAppStorage.sol";
import {LibAccounting} from "../libraries/LibAccounting.sol";
import {LibCommon} from "../libraries/LibCommon.sol";
import {LibRegistry} from "../libraries/LibRegistry.sol";
import {IRegistryFacet} from "../interfaces/IRegistryFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract RegistryFacet is IRegistryFacet {
    using EnumerableSet for *;

    /// @dev State variables 
    AppStorage internal s;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: TASKS RELATED FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Function used to register a user task for automation.
    /// @param _payloadTx Includes the target smart contract address and the data to call in abi encoded form.
    /// @param _expiryTime Time after which the task gets expired.
    /// @param _maxGasAmount Maximum amount of gas for the automation task.
    /// @param _gasPriceCap Maximum gas willing to pay for the task.
    /// @param _automationFeeCapForCycle Maximum automation fee for a cycle to be paid ever.
    /// @param _priority Priority for the task. 0 for default priority.
    /// @param _auxData Auxiliary data to be passed.
    function register(
        bytes memory _payloadTx,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint64 _priority,
        bytes[] memory _auxData
    ) external {        
        uint64 taskIndex = LibRegistry.registerTask(
            _payloadTx,
            _expiryTime,
            _maxGasAmount,
            _gasPriceCap,
            _automationFeeCapForCycle,
            _priority,
            LibCommon.TaskType.UST,
            _auxData
        );
        
        RegistryState storage registryState = LibAppStorage.registryState();

        registryState.totalDepositedAutomationFees += _automationFeeCapForCycle;

        uint128 flatRegistrationFee = LibAppStorage.activeConfig().flatRegistrationFeeWei;
        uint128 fee = flatRegistrationFee + _automationFeeCapForCycle;

        bool sent = IERC20(s.erc20Supra).transferFrom(msg.sender, address(this), fee);
        if (!sent) { revert TransferFailed(); }

        emit TaskRegistered(taskIndex, msg.sender, flatRegistrationFee, _automationFeeCapForCycle, registryState.tasks[taskIndex]);
    }

    /// @notice Function to register a system task. Reverts if caller is not authorized.
    /// @param _payloadTx Includes the target smart contract address and the data to call in abi encoded form.
    /// @param _expiryTime Time after which the task gets expired.
    /// @param _maxGasAmount Maximum amount of gas for the automation task.
    /// @param _priority Priority for the task. 0 for default priority.
    /// @param _auxData Auxiliary data to be passed.
    function registerSystemTask(
        bytes memory _payloadTx,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _priority,
        bytes[] memory _auxData
    ) external {
        if (!isAuthorizedSubmitter(msg.sender)) { revert UnauthorizedAccount(); }
        
        uint64 taskIndex = LibRegistry.registerTask(
            _payloadTx,
            _expiryTime,
            _maxGasAmount,
            0,
            0,
            _priority,
            LibCommon.TaskType.GST,
            _auxData
        );

        emit SystemTaskRegistered(taskIndex, msg.sender, block.timestamp, LibAppStorage.registryState().tasks[taskIndex]);
    }

    /// @notice Cancels the automation tasks with specified task indexes.
    /// Only existing task, which is PENDING or ACTIVE, can be cancelled and only by task owner.
    /// If the task is
    ///   - active, its state is updated to be CANCELLED.
    ///   - pending, it is removed form the list.
    ///   - cancelled, an error is reported
    /// Committed gas limit is updated by reducing it with the max gas amount of the cancelled task.
    /// @param _taskIndexes Array of task indexes to be cancelled.
    function cancelTasks(
        uint64[] memory _taskIndexes
    ) external {
        validateInput(_taskIndexes);
        
        LibCommon.TaskCancelled[] memory cancelledTasks = new LibCommon.TaskCancelled[](_taskIndexes.length);    
        uint256 counter;
        
        for (uint256 i; i < _taskIndexes.length; i++) {
            uint64 taskId = _taskIndexes[i];
            if (LibCommon.ifTaskExists(taskId)) {
                cancelledTasks[counter++] = LibRegistry.cancelTask(taskId, false);
            }
        }

        if (counter > 0) {
            emit TasksCancelled(cancelledTasks, msg.sender);
        } 
    }

    /// @notice Cancels the system automation tasks with specified task indexes.
    /// Only existing task, which is PENDING or ACTIVE, can be cancelled and only by task owner.
    /// If the task is
    ///   - active, its state is updated to be CANCELLED.
    ///   - pending, it is removed form the list.
    ///   - cancelled, an error is reported
    /// Committed gas limit is updated by reducing it with the max gas amount of the cancelled task.
    /// @param _taskIndexes Array of task indexes to be cancelled.
    function cancelSystemTasks(
        uint64[] memory _taskIndexes
    ) external {
        validateInput(_taskIndexes);

        LibCommon.TaskCancelled[] memory cancelledTasks = new LibCommon.TaskCancelled[](_taskIndexes.length);    
        uint256 counter;

        for (uint256 i; i < _taskIndexes.length; i++) {
            uint64 taskId = _taskIndexes[i];
            if (LibCommon.ifTaskExists(taskId)) {
                cancelledTasks[counter++] = LibRegistry.cancelTask(taskId, true);
            }
        }

        if (counter > 0) {
            emit TasksCancelled(cancelledTasks, msg.sender);
        } 
    }

    /// @notice Immediately stops automation tasks for the specified `_taskIndexes`.
    /// Only tasks that exist and are owned by the sender can be stopped.
    /// If any of the specified tasks are not owned by the sender, the transaction will abort.
    /// When a task is stopped, the committed gas for the next cycle is reduced
    /// by the max gas amount of the stopped task. Half of the remaining task fee is refunded.
    /// @param _taskIndexes Array of task indexes to be stopped.
    function stopTasks(
        uint64[] memory _taskIndexes
    ) external {
        validateInput(_taskIndexes);

        LibCommon.TaskStopped[] memory stoppedTasks = new LibCommon.TaskStopped[](_taskIndexes.length);    
        uint64 cycleEndTime = LibCommon.getCycleEndTime();
        uint256 counter;
        uint128 totalRefundFee;

        // Loop through each task index to validate and stop the task
        for (uint256 i = 0; i < _taskIndexes.length; i++) {
            if (LibCommon.ifTaskExists(_taskIndexes[i])) {
                (LibCommon.TaskStopped memory ts, uint128 refund) = LibRegistry.stopTask(_taskIndexes[i], cycleEndTime, false);
                stoppedTasks[counter++] = ts;
                totalRefundFee += refund;
            }
        }

        // Refund and emit event if any tasks were stopped
        if (counter > 0) {  
            LibAccounting.refund(msg.sender, totalRefundFee);

            // Emit task stopped event
            emit TasksStopped(stoppedTasks, msg.sender);
        }
    }

    /// @notice Immediately stops system automation tasks for the specified `_taskIndexes`.
    /// Only tasks that exist and are owned by the sender can be stopped.
    /// If any of the specified tasks are not owned by the sender, the transaction will abort.
    /// When a task is stopped, the committed gas for the next cycle is reduced
    /// by the max gas amount of the stopped task.
    /// @param _taskIndexes Array of task indexes to be stopped.
    function stopSystemTasks(
        uint64[] memory _taskIndexes
    ) external {
        validateInput(_taskIndexes);
        
        LibCommon.TaskStopped[] memory stoppedTasks = new LibCommon.TaskStopped[](_taskIndexes.length);
        uint64 cycleEndTime = LibCommon.getCycleEndTime();
        uint256 counter;
        
        // Loop through each task index to validate and stop the task
        for (uint256 i = 0; i < _taskIndexes.length; i++) {
            uint64 taskId = _taskIndexes[i];
            if (LibCommon.ifTaskExists(taskId)) {
                (LibCommon.TaskStopped memory ts,) = LibRegistry.stopTask(taskId, cycleEndTime, true);
                stoppedTasks[counter++] = ts;
            }
        }

        if (counter > 0) {
            // Emit task stopped event
            emit TasksStopped(stoppedTasks, msg.sender);
        }
    }

    /// @notice Helper function for validation.
    function validateInput(uint64[] memory _taskIndexes) private view {
        if (!s.automationEnabled) { revert AutomationNotEnabled(); }
        if (!LibCommon.isCycleStarted()) revert CycleTransitionInProgress();
        if (_taskIndexes.length == 0) revert TaskIndexesCannotBeEmpty();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::  

    /// @notice Returns all the automation tasks available in the registry.
    function getTaskIdList() external view returns (uint256[] memory) {
        return LibAppStorage.registryState().taskIdList.values();
    }

    /// @notice Returns all the automation tasks registered by a user.
    /// @param _user Address of the user to fetch registered tasks for.
    function getUserTasks(address _user) external view returns (uint256[] memory) {
        return LibAppStorage.registryState().userTasks[_user].values();
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

    /// @notice Checks if the input account is an authorized submitter to submit system automation tasks.
    /// @param _account Address to check if it's authorized.
    function isAuthorizedSubmitter(address _account) public view returns (bool) {
        return s.authorizedAccounts.contains(_account);
    }

    /// @notice Returns the total number of active tasks.
    function getTotalActiveTasks() external view returns (uint256) {
        return LibAppStorage.registryState().activeTaskIds.length();
    }

    /// @notice Returns all the active task indexes.
    function getActiveTaskIds() external view returns (uint256[] memory) {
        return LibAppStorage.registryState().activeTaskIds.values();
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

    /// @notice Calculates automation fee per second for the specified task occupancy
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and current registry
    /// maximum allowed occupancy.
    function calculateAutomationFeeMultiplierForCommittedOccupancy(uint128 _totalCommittedMaxGas) external view returns (uint128) {
        return LibAccounting.calculateAutomationFeeMultiplierForCommittedOccupancy(_totalCommittedMaxGas);
    }
    
    /// @notice Calculates the automation fee multiplier for current cycle. 
    function calculateAutomationFeeMultiplierForCurrentCycle() external view returns (uint128) {
        return LibAccounting.calculateAutomationFeeMultiplierForCurrentCycle();
    }

    /// @notice Estimates automation fee for the next cycle for specified task occupancy for the configured cycle-interval
    /// referencing the current automation registry fee parameters, current total occupancy and registry maximum allowed
    /// occupancy for the next cycle.
    function estimateAutomationFee(uint128 _taskOccupancy) external view returns (uint128) {
        return LibAccounting.estimateAutomationFeeWithCommittedOccupancyInternal(_taskOccupancy, LibAppStorage.registryState().gasCommittedForNextCycle);
    }

    /// @notice Estimates automation fee the next cycle for specified task occupancy for the configured cycle-interval
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and registry
    /// maximum allowed occupancy for the next cycle.
    function estimateAutomationFeeWithCommittedOccupancy(
        uint128 _taskOccupancy,
        uint128 _committedOccupancy
    ) external view returns (uint128) {
        return LibAccounting.estimateAutomationFeeWithCommittedOccupancyInternal(
            _taskOccupancy,
            _committedOccupancy
        );
    }
}
