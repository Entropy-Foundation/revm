// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, TaskMetadata} from "../libraries/LibAppStorage.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {LibRegistry} from "../libraries/LibRegistry.sol";
import {LibCore} from "../libraries/LibCore.sol";
import {IRegistryFacet} from "../interfaces/IRegistryFacet.sol";

contract RegistryFacet is IRegistryFacet {
    using EnumerableSet for *;
    using LibRegistry for *;

    /// @dev Defines divisor for refunds of deposit fees with penalty
    /// Factor of `2` suggests that `1/2` of the deposit will be refunded.
    uint8 constant REFUND_FACTOR = 2;

    /// @notice Address of the transaction hash precompile.
    address public constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000053555001;

    /// @dev State variables 
    AppStorage internal s;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: EVENTS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @notice Emitted when a user task is registered.
    event TaskRegistered(
        uint64 indexed taskIndex, 
        address indexed owner, 
        uint128 registrationFee, 
        uint128 lockedDepositFee, 
        TaskMetadata taskMetadata
    );

    /// @notice Emitted when a system task is registered.
    event SystemTaskRegistered(
        uint64 indexed taskIndex, 
        address indexed owner, 
        uint256 timestamp, 
        TaskMetadata taskMetadata
    );
    
    /// @notice Emitted when a task is cancelled.
    event TaskCancelled(
        uint64 indexed taskIndex,
        address indexed owner,
        bytes32 indexed regHash
    );

    /// @notice Emitted when a task is stopped.
    event TasksStopped(
        LibUtils.TaskStopped[] indexed stoppedTasks,
        address indexed owner
    );

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
        uint64 regTime = uint64(block.timestamp);
        
        LibRegistry.updateStateForValidRegistration(
            totalTasks(),
            regTime,
            _expiryTime,
            LibUtils.TaskType.UST,
            _payloadTx, 
            _maxGasAmount, 
            _gasPriceCap,
            _automationFeeCapForCycle
        );

        uint64 taskIndex = s.registryState.currentIndex; 

        TaskMetadata memory taskMetadata = TaskMetadata({ 
            maxGasAmount: _maxGasAmount, 
            gasPriceCap: _gasPriceCap, 
            automationFeeCapForCycle: _automationFeeCapForCycle, 
            depositFee: _automationFeeCapForCycle, 
            txHash: readTxHash(), 
            taskIndex: taskIndex, 
            registrationTime: regTime, 
            expiryTime: _expiryTime, 
            priority: taskIndex,    // priority set to taskIndex by default 
            owner: msg.sender, 
            taskType: LibUtils.TaskType.UST, 
            taskState: LibUtils.TaskState.PENDING, 
            payloadTx: _payloadTx, 
            auxData: _auxData
        }); 
        
        s.registryState.tasks[taskIndex] = taskMetadata; 
        require(s.registryState.taskIdList.add(taskIndex), TaskIndexNotUnique());
        s.registryState.currentIndex += 1;
        s.registryState.totalDepositedAutomationFees += _automationFeeCapForCycle;

        uint128 flatRegistrationFee = s.activeConfig.flatRegistrationFeeWei;
        uint128 fee = flatRegistrationFee + _automationFeeCapForCycle;
        LibRegistry.chargeFees(msg.sender, fee);

        emit TaskRegistered(taskIndex, msg.sender, flatRegistrationFee, _automationFeeCapForCycle, s.registryState.tasks[taskIndex]);
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
        if(!isAuthorizedSubmitter(msg.sender)) { revert UnauthorizedAccount(); }
        
        uint64 regTime = uint64(block.timestamp);
        LibRegistry.updateStateForValidRegistration(
            totalSystemTasks(),
            regTime,
            _expiryTime,
            LibUtils.TaskType.GST,
            _payloadTx, 
            _maxGasAmount, 
            0,
            0
        );
                
        uint64 taskIndex = s.registryState.currentIndex; 
        uint64 taskPriority = _priority == 0 ? taskIndex : _priority;   // Defaults to taskIndex as priority if 0 is passed
        TaskMetadata memory taskMetadata = TaskMetadata({ 
            maxGasAmount: _maxGasAmount, 
            gasPriceCap: 0, 
            automationFeeCapForCycle: 0, 
            depositFee: 0, 
            txHash: readTxHash(), 
            taskIndex: taskIndex, 
            registrationTime: regTime, 
            expiryTime: _expiryTime, 
            priority: taskPriority, 
            owner: msg.sender, 
            taskType: LibUtils.TaskType.GST, 
            taskState: LibUtils.TaskState.PENDING, 
            payloadTx: _payloadTx, 
            auxData: _auxData 
        });

        s.registryState.tasks[taskIndex] = taskMetadata; 
        require(s.registryState.taskIdList.add(taskIndex), TaskIndexNotUnique());
        require(s.registryState.sysTaskIds.add(taskIndex), TaskIndexNotUnique());
        s.registryState.currentIndex += 1;

        emit SystemTaskRegistered(taskIndex, msg.sender, block.timestamp, s.registryState.tasks[taskIndex]);
    }

    /// @notice Cancels an automation task with specified task index.
    /// Only existing task, which is PENDING or ACTIVE, can be cancelled and only by task owner.
    /// If the task is
    ///   - active, its state is updated to be CANCELLED.
    ///   - pending, it is removed form the list.
    ///   - cancelled, an error is reported
    /// Committed gas limit is updated by reducing it with the max gas amount of the cancelled task.
    /// @param _taskIndex Index of the task.
    function cancelTask(
        uint64 _taskIndex
    ) external {
        // Check if automation is enabled
        if (!s.automationEnabled) { revert AutomationNotEnabled(); }

        if(!LibRegistry.isCycleStarted()) { revert CycleTransitionInProgress(); }
        if(!LibRegistry.ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }

        TaskMetadata memory task = s.registryState.tasks[_taskIndex];

        if(task.taskType == LibUtils.TaskType.GST) { revert UnsupportedTaskOperation(); }
        if(task.owner != msg.sender) { revert UnauthorizedAccount(); }
        if(task.taskState == LibUtils.TaskState.CANCELLED) { revert AlreadyCancelled(); }
        
        if (task.taskState == LibUtils.TaskState.PENDING) {
            // When Pending tasks are cancelled, refund of the deposit fee is done with penalty
            _removeTask(_taskIndex, false); 
            bool result = LibRegistry.safeDepositRefund(
                _taskIndex,
                task.owner,
                task.depositFee / REFUND_FACTOR,
                task.depositFee
            );
            if(!result) { revert ErrorDepositRefund(); }            
        } else { 
            // It is safe not to check the state as above, the cancelled tasks are already rejected.
            // Active tasks will be refunded the deposited amount fully at the end of the cycle.
            s.registryState.tasks[_taskIndex].taskState = LibUtils.TaskState.CANCELLED;
        }

        // This check means the task was expected to be executed in the next cycle, but it has been cancelled.
        // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
        if (task.expiryTime > LibCore.getCycleEndTime()) {
            LibRegistry.updateGasCommittedForNextCycle(task.taskType, task.maxGasAmount);
        }

        emit TaskCancelled( _taskIndex, task.owner, task.txHash);
    }

    /// @notice Cancels a system automation task with specified task index.
    /// Only existing task, which is PENDING or ACTIVE, can be cancelled and only by task owner.
    /// If the task is
    ///   - active, its state is updated to be CANCELLED.
    ///   - pending, it is removed form the list.
    ///   - cancelled, an error is reported
    /// Committed gas limit is updated by reducing it with the max gas amount of the cancelled task.
    /// @param _taskIndex Index of the task.
    function cancelSystemTask(
        uint64 _taskIndex
    ) external {
        // Check if automation is enabled
        if (!s.automationEnabled) { revert AutomationNotEnabled(); }

        if(!LibRegistry.isCycleStarted()) { revert CycleTransitionInProgress(); }
        if(!LibRegistry.ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }
        if(!LibRegistry.ifSysTaskExists(_taskIndex)) { revert SystemTaskDoesNotExist(); }

        TaskMetadata memory task = s.registryState.tasks[_taskIndex];

        // Check if GST
        if(task.taskType == LibUtils.TaskType.UST) { revert UnsupportedTaskOperation(); }

        if(task.owner != msg.sender) { revert UnauthorizedAccount(); }
        if(task.taskState == LibUtils.TaskState.CANCELLED) { revert AlreadyCancelled(); }

        if(task.taskState == LibUtils.TaskState.PENDING) {
            _removeTask(_taskIndex, true);
        } else {
            s.registryState.tasks[_taskIndex].taskState = LibUtils.TaskState.CANCELLED;
        }

        // This check means the task was expected to be executed in the next cycle, but it has been cancelled.
        // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
        if(task.expiryTime > LibCore.getCycleEndTime()) {
            LibRegistry.updateGasCommittedForNextCycle(task.taskType, task.maxGasAmount);
        }

        emit TaskCancelled(_taskIndex, msg.sender, task.txHash);
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
        // Check if automation is enabled
        if (!s.automationEnabled) { revert AutomationNotEnabled(); }

        if(!LibRegistry.isCycleStarted()) { revert CycleTransitionInProgress(); }
        if(_taskIndexes.length == 0) { revert TaskIndexesCannotBeEmpty(); }

        LibUtils.TaskStopped[] memory stoppedTaskDetails = new LibUtils.TaskStopped[](_taskIndexes.length);
        uint256 counter = 0;
        
        uint128 totalRefundFee = 0;

        // Calculate refundable fee for this remaining time task in current cycle
        uint64 currentTime = uint64(block.timestamp);
        uint64 cycleEndTime = LibCore.getCycleEndTime();
        uint64 residualInterval = cycleEndTime <= currentTime ? 0 : (cycleEndTime - currentTime);

        // Loop through each task index to validate and stop the task
        for (uint256 i = 0; i < _taskIndexes.length; i++) {
            if(LibRegistry.ifTaskExists(_taskIndexes[i])) {
                TaskMetadata memory task = s.registryState.tasks[_taskIndexes[i]];

                // Check if authorised
                if(msg.sender != task.owner) { revert UnauthorizedAccount(); }
                
                // Check if UST
                if(task.taskType == LibUtils.TaskType.GST) { revert UnsupportedTaskOperation(); }

                // Remove task from the registry
                _removeTask(_taskIndexes[i], false);
                // Remove from active tasks
                require(s.registryState.activeTaskIds.remove(_taskIndexes[i]), TaskIndexNotFound());

                // This check means the task was expected to be executed in the next cycle, but it has been stopped.
                // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
                // Also it checks that task should not be cancelled.
                if(task.taskState != LibUtils.TaskState.CANCELLED && task.expiryTime > cycleEndTime) {
                    // Reduce committed gas by the stopped task's max gas
                    LibRegistry.updateGasCommittedForNextCycle(task.taskType, task.maxGasAmount);
                }

                (uint128 cycleFeeRefund, uint128 depositRefund) = LibRegistry.unlockDepositAndCycleFee(
                    _taskIndexes[i],
                    task.taskState,
                    task.expiryTime,
                    task.maxGasAmount,
                    residualInterval,
                    uint64(currentTime),
                    task.depositFee
                );
                totalRefundFee += (cycleFeeRefund + depositRefund);


                // Add to stopped tasks
                LibUtils.TaskStopped memory taskStopped = LibUtils.TaskStopped(
                    _taskIndexes[i],
                    depositRefund,
                    cycleFeeRefund,
                    task.txHash
                );
                stoppedTaskDetails[counter] = taskStopped;
                counter += 1;
            }
        }

        // Refund and emit event if any tasks were stopped
        if(stoppedTaskDetails.length > 0) {  
            LibRegistry.refund(msg.sender, totalRefundFee);

            // Emit task stopped event
            emit TasksStopped(
                stoppedTaskDetails,
                msg.sender
            );
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
        // Check if automation is enabled
        if (!s.automationEnabled) { revert AutomationNotEnabled(); }

        if(!LibRegistry.isCycleStarted()) { revert CycleTransitionInProgress(); }

        // Ensure that task indexes are provided
        if(_taskIndexes.length == 0) { revert TaskIndexesCannotBeEmpty(); }

        LibUtils.TaskStopped[] memory stoppedTaskDetails = new LibUtils.TaskStopped[](_taskIndexes.length);
        uint256 counter = 0;

        // Loop through each task index to validate and stop the task
        for (uint256 i = 0; i < _taskIndexes.length; i++) {
            if(LibRegistry.ifTaskExists(_taskIndexes[i])) {
                TaskMetadata memory task = s.registryState.tasks[_taskIndexes[i]];

                if(task.owner != msg.sender) { revert UnauthorizedAccount(); }

                // Check if GST
                if(task.taskType == LibUtils.TaskType.UST) { revert UnsupportedTaskOperation(); }
                _removeTask(_taskIndexes[i], true);
                // Remove from active tasks
                require(s.registryState.activeTaskIds.remove(_taskIndexes[i]), TaskIndexNotFound());

                if(task.taskState != LibUtils.TaskState.CANCELLED && task.expiryTime > LibCore.getCycleEndTime()) {
                    LibRegistry.updateGasCommittedForNextCycle(task.taskType, task.maxGasAmount);
                }

                // Add to stopped tasks
                LibUtils.TaskStopped memory taskStopped = LibUtils.TaskStopped(
                    _taskIndexes[i],
                    0,
                    0,
                    task.txHash
                );
                stoppedTaskDetails[counter] = taskStopped;
                counter += 1;
            }
        }

        if(stoppedTaskDetails.length > 0) {
            // Emit task stopped event
            emit TasksStopped(
                stoppedTaskDetails,
                msg.sender
            );
        }
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: HELPER FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Read tx hash via precompile. Reverts if precompile missing/fails.
    function readTxHash() private view returns (bytes32) {
        (bool ok, bytes memory out) = TX_HASH_PRECOMPILE.staticcall("");
        require(ok, FailedToCallTxHashPrecompile());
        require(out.length == 32, TxnHashLengthShouldBe32(uint64(out.length)));
        return abi.decode(out, (bytes32));
    }
    
    /// @notice Function to remove a task from the registry.
    /// @param _taskIndex Index of the task to remove. 
    /// @param _removeFromSysReg Wheather to remove from system task registry.
    function _removeTask(uint64 _taskIndex, bool _removeFromSysReg) private {
        if(_removeFromSysReg) {
            require(s.registryState.sysTaskIds.remove(_taskIndex), TaskIndexNotFound());
        }

        delete s.registryState.tasks[_taskIndex];
        require(s.registryState.taskIdList.remove(_taskIndex), TaskIndexNotFound());
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::  

    /// @notice Returns all the automation tasks available in the registry.
    function getTaskIds() external view returns (uint256[] memory) {
        return s.registryState.taskIdList.values();
    }

    /// @notice Returns all the system tasks available in the registry.
    function getSystemTaskIds() external view returns (uint256[] memory) {
        return s.registryState.sysTaskIds.values();
    }

    /// @notice Returns the owner of the task 
    /// @param _taskIndex Task index of the task to query.
    function getTaskOwner(uint64 _taskIndex) external view returns (address) {
        return s.registryState.tasks[_taskIndex].owner;
    }

    /// @notice Returns the next task index.
    function getNextTaskIndex() external view returns (uint64) {
        return s.registryState.currentIndex;
    }

    /// @notice Returns the number of total tasks.
    function totalTasks() public view returns (uint256) {
        return s.registryState.taskIdList.length();
    }

    /// @notice Returns the number of total system tasks.
    function totalSystemTasks() public view returns (uint256) {
        return s.registryState.sysTaskIds.length();
    }

    /// @notice Returns if a task exists in the registry.
    /// @param _taskIndex Task index to check existence for.
    function ifTaskExists(uint64 _taskIndex) external view  returns (bool) {
        return LibRegistry.ifTaskExists(_taskIndex);
    }

    /// @notice Returns if a system task exists in the registry.
    /// @param _taskIndex Task index of the system task to check existence for.
    function ifSysTaskExists(uint64 _taskIndex) external view returns (bool) {
        return LibRegistry.ifSysTaskExists(_taskIndex);
    }

    /// @notice Returns the details of a task. Reverts if task doesn't exist.
    function getTaskDetails(uint64 _taskIndex) external view returns (TaskMetadata memory) {
        return LibRegistry.getTask(_taskIndex);
    }
    
    /// @notice Retrieves the details of automation tasks by their task index. Skips a task if it doesn't exist.
    /// @param _taskIndexes Input task indexes to get details of.
    /// @return Task details of the tasks that exist.
    function getTaskDetailsBulk(uint64[] memory _taskIndexes) external view returns (TaskMetadata[] memory) {
        uint256 count = _taskIndexes.length;
        TaskMetadata[] memory temp =  new TaskMetadata[](count);
        uint256 exists;

        for (uint256 i = 0; i < count; i++) {
            if(LibRegistry.ifTaskExists(_taskIndexes[i])) {
                temp[exists] = s.registryState.tasks[_taskIndexes[i]];
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
        return s.registryState.activeTaskIds.length();
    }

    /// @notice Returns all the active task indexes.
    function getActiveTaskIds() external view returns (uint256[] memory) {
        return s.registryState.activeTaskIds.values();
    }

    /// @notice Checks whether there is an active task in registry with specified input task index.
    function hasActiveUserTask(address _account, uint64 _taskIndex) external view returns (bool) {
        return hasActiveTaskOfType(_account, _taskIndex, LibUtils.TaskType.UST);
    }

    /// @notice Checks whether there is an active system task in registry with specified input task index.
    function hasActiveSystemTask(address _account, uint64 _taskIndex) external view returns (bool) {
        return hasActiveTaskOfType(_account, _taskIndex, LibUtils.TaskType.GST);
    }

    /// @notice Checks whether there is an active task in registry with specified input task index of the input type.
    /// The type can be either 0 for user submitted tasks, and 1 for governance authorized tasks.
    function hasActiveTaskOfType(address _account, uint64 _taskIndex, LibUtils.TaskType _type) public view returns (bool) {
        TaskMetadata storage task = s.registryState.tasks[_taskIndex]; 
        return task.owner == _account && task.taskState != LibUtils.TaskState.PENDING && task.taskType == _type;
    }

    /// @notice Returns the gas committed for the next cycle.
    function getGasCommittedForNextCycle() external view returns (uint128) {
        return s.registryState.gasCommittedForNextCycle;
    }

    /// @notice Returns the gas committed for the current cycle.
    function getGasCommittedForCurrentCycle() external view returns (uint128) {
        return s.registryState.gasCommittedForThisCycle;
    }

    /// @notice Returns the system gas committed for the next cycle.
    function getSystemGasCommittedForNextCycle() external view returns (uint128) {
        return s.registryState.sysGasCommittedForNextCycle;
    }

    /// @notice Returns the system gas committed for the current cycle.
    function getSystemGasCommittedForCurrentCycle() external view returns (uint128) {
        return s.registryState.sysGasCommittedForThisCycle;
    }

    /// @notice Returns the registry max gas cap for the next cycle.    
    function getNextCycleRegistryMaxGasCap() external view returns (uint128) {
        return s.registryState.nextCycleRegistryMaxGasCap;
    }

    /// @notice Returns the system registry max gas cap for the next cycle.    
    function getNextCycleSysRegistryMaxGasCap() external view returns (uint128) {
        return s.registryState.nextCycleSysRegistryMaxGasCap;
    }

    /// @notice Returns the locked fees for the cycle. 
    function getCycleLockedFees() external view returns (uint256) {
        return s.registryState.cycleLockedFees;
    }

    /// @notice Returns the total amount of automation fees deposited.
    function getTotalDepositedAutomationFees() external view returns (uint256) {
        return s.registryState.totalDepositedAutomationFees;
    }

    /// @notice Returns the total amount locked which comprises of 'cycleLockedFees' and 'totalDepositedAutomationFees'. 
    function getTotalLockedBalance() external view returns (uint256) {
        return s.registryState.cycleLockedFees + s.registryState.totalDepositedAutomationFees;
    }

    /// @notice Calculates automation fee per second for the specified task occupancy
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and current registry
    /// maximum allowed occupancy.
    function calculateAutomationFeeMultiplierForCommittedOccupancy(uint128 _totalCommittedMaxGas) external view returns (uint128) {
        return LibRegistry.calculateAutomationFeeMultiplierForCommittedOccupancy(_totalCommittedMaxGas);
    }
    
    /// @notice Calculates the automation fee multiplier for current cycle. 
    function calculateAutomationFeeMultiplierForCurrentCycle() external view returns (uint128) {
        return LibRegistry.calculateAutomationFeeMultiplierForCurrentCycle();
    }

    /// @notice Estimates automation fee for the next cycle for specified task occupancy for the configured cycle-interval
    /// referencing the current automation registry fee parameters, current total occupancy and registry maximum allowed
    /// occupancy for the next cycle.
    function estimateAutomationFee(uint128 _taskOccupancy) external view returns (uint128) {
        return LibRegistry.estimateAutomationFeeWithCommittedOccupancyInternal(_taskOccupancy, s.registryState.gasCommittedForNextCycle);
    }

    /// @notice Estimates automation fee the next cycle for specified task occupancy for the configured cycle-interval
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and registry
    /// maximum allowed occupancy for the next cycle.
    function estimateAutomationFeeWithCommittedOccupancy(
        uint128 _taskOccupancy,
        uint128 _committedOccupancy
    ) external view returns (uint128) {
        return LibRegistry.estimateAutomationFeeWithCommittedOccupancyInternal(
            _taskOccupancy,
            _committedOccupancy
        );
    }
}
