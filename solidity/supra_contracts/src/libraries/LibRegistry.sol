// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {LibAccounting} from "./LibAccounting.sol";
import {LibCommon} from "./LibCommon.sol";
import {LibUtils} from "./LibUtils.sol";
import {AppStorage, LibAppStorage, TaskMetadata} from "./LibAppStorage.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

library LibRegistry {
    using LibUtils for address;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice Address of the transaction hash precompile.
    address public constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000053555001;

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ERRORS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    error AlreadyCancelled();
    error RegistrationDisabled();
    error AutomationNotEnabled();
    error CycleTransitionInProgress();
    error ErrorDepositRefund();
    error FailedToCallTxHashPrecompile();
    error TxnHashLengthShouldBe32(uint64);
    error InvalidMaxGasAmount();
    error GasCommittedExceedsMaxGasCap();
    error GasCommittedValueUnderflow();
    error InsufficientFeeCapForCycle(uint128 estimatedAutomationFeeForCycle);
    error InvalidExpiryTime();
    error InvalidGasPriceCap();
    error InvalidTaskDuration();
    error TaskCapacityReached();
    error TaskExpiresBeforeNextCycle();
    error TaskIndexNotFound();
    error TaskIndexNotUnique();
    error UnauthorizedAccount();
    error UnsupportedTaskOperation();

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: PRIVATE FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function to validate the task duration.
    function validateTaskDuration(
        uint64 _regTime,
        uint64 _expiryTime,    
        uint64 _taskDurationCap,
        uint64 _cycleEndTime
    ) private pure {
        if (_expiryTime <= _regTime) { revert InvalidExpiryTime(); }
        
        uint64 taskDuration = _expiryTime - _regTime;
        if (taskDuration > _taskDurationCap) { revert InvalidTaskDuration(); }
        
        if ( _expiryTime <= _cycleEndTime) { revert TaskExpiresBeforeNextCycle(); }
    }

    /// @notice Helper function to validate the inputs while registering a task.
    function validateInputs(bytes memory _payloadTx, uint128 _maxGasAmount) private view {
        ( , address payloadTarget, , ) = abi.decode(_payloadTx, (uint128, address, bytes, LibCommon.AccessListEntry[]));
        payloadTarget.validateContractAddress();
        
        if (_maxGasAmount == 0) { revert InvalidMaxGasAmount(); }
    }

    /// @notice Read tx hash via precompile. Reverts if precompile missing/fails.
    function readTxHash() private view returns (bytes32) {
        (bool ok, bytes memory out) = TX_HASH_PRECOMPILE.staticcall("");
        require(ok, FailedToCallTxHashPrecompile());
        require(out.length == 32, TxnHashLengthShouldBe32(uint64(out.length)));
        return abi.decode(out, (bytes32));
    }

    function validateOwnerType(
        address _owner,
        LibCommon.TaskType _taskType,
        bool _isGst
    ) private view {
        // Check if authorised
        if (msg.sender != _owner) { revert UnauthorizedAccount(); }

        // Enforce task type
        if (_isGst) {
            if (_taskType == LibCommon.TaskType.UST) {
                revert UnsupportedTaskOperation();
            }
        } else {
            if (_taskType == LibCommon.TaskType.GST) {
                revert UnsupportedTaskOperation();
            }
        }
    }

    /// @notice Helper function that performs validation and updates state for a valid task.
    function updateStateForValidRegistration(
        uint256 _totalTasks, 
        uint64 _regTime,
        uint64 _expiryTime,
        bytes memory _payloadTx, 
        uint128 _maxGasAmount, 
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        bool _isUst
    ) private {
        AppStorage storage s = LibAppStorage.appStorage();

        // Check if automation and registration is enabled
        if (!s.automationEnabled) { revert AutomationNotEnabled(); }
        if (!s.registrationEnabled) { revert RegistrationDisabled(); }

        if (!LibCommon.isCycleStarted()) { revert CycleTransitionInProgress(); }
   
        uint64 taskDurationCap;
        uint128 gasCommittedForNextCycle;
        uint128 nextCycleRegistryMaxGasCap;
        if (_isUst) {
            if (_totalTasks >= s.activeConfig.taskCapacity) { revert TaskCapacityReached(); }
            if (_gasPriceCap == 0) { revert InvalidGasPriceCap(); }

            gasCommittedForNextCycle = s.registryState.gasCommittedForNextCycle;
            uint128 estimatedAutomationFeeForCycle = LibAccounting.estimateAutomationFeeWithCommittedOccupancyInternal(_maxGasAmount, gasCommittedForNextCycle);
            if (_automationFeeCapForCycle < estimatedAutomationFeeForCycle) { revert InsufficientFeeCapForCycle(estimatedAutomationFeeForCycle); }
            taskDurationCap = s.activeConfig.taskDurationCapSecs;
            nextCycleRegistryMaxGasCap = s.registryState.nextCycleRegistryMaxGasCap;
        } else {
            if (_totalTasks >= s.activeConfig.sysTaskCapacity) { revert TaskCapacityReached(); }

            gasCommittedForNextCycle = s.registryState.sysGasCommittedForNextCycle;
            taskDurationCap = s.activeConfig.sysTaskDurationCapSecs;
            nextCycleRegistryMaxGasCap = s.registryState.nextCycleSysRegistryMaxGasCap;
        }

        validateTaskDuration(_regTime, _expiryTime, taskDurationCap, s.startTime + s.durationSecs);
        validateInputs(_payloadTx, _maxGasAmount);

        uint128 gasCommitted = _maxGasAmount + gasCommittedForNextCycle;
        if (gasCommitted > nextCycleRegistryMaxGasCap) { revert GasCommittedExceedsMaxGasCap(); }

        if (_isUst) {
            s.registryState.gasCommittedForNextCycle = gasCommitted;
        } else {
            s.registryState.sysGasCommittedForNextCycle = gasCommitted;
        } 
    }

    function createAndStoreTask(
        bytes memory _payloadTx,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint64 _priority,
        LibCommon.TaskType _taskType,
        uint64 _regTime,
        bool _isUst,
        bytes[] memory _auxData
    ) private returns (uint64 taskIndex) {
        AppStorage storage s = LibAppStorage.appStorage();

        taskIndex = s.registryState.currentIndex;

        uint64 taskPriority;
        if (_isUst) {
            taskPriority = taskIndex;
        } else {
            taskPriority = _priority == 0 ? taskIndex : _priority;
        }
        
        TaskMetadata memory taskMetadata = TaskMetadata({
            maxGasAmount: _maxGasAmount,
            gasPriceCap: _gasPriceCap,
            automationFeeCapForCycle: _automationFeeCapForCycle,
            depositFee: _automationFeeCapForCycle,
            txHash: readTxHash(),
            taskIndex: taskIndex,
            registrationTime: _regTime,
            expiryTime: _expiryTime,
            priority: taskPriority,
            owner: msg.sender,
            taskType: _taskType,
            taskState: LibCommon.TaskState.PENDING,
            payloadTx: _payloadTx,
            auxData: _auxData
        });
    
        s.registryState.tasks[taskIndex] = taskMetadata;
        require(s.registryState.taskIdList.add(taskIndex), TaskIndexNotUnique());
        require(s.registryState.userTasks[msg.sender].add(taskIndex), TaskIndexNotUnique());
    
        if (!_isUst) {
            require(s.registryState.sysTaskIds.add(taskIndex), TaskIndexNotUnique());
        }
        s.registryState.currentIndex += 1;
    }

    function updateGasCommittedForNextCycle(bool _isGst, uint128 _maxGasAmount) private {
        AppStorage storage s = LibAppStorage.appStorage();

        uint128 gasCommittedForNextCycle = _isGst ? s.registryState.sysGasCommittedForNextCycle : s.registryState.gasCommittedForNextCycle;        
        if (gasCommittedForNextCycle < _maxGasAmount) { revert GasCommittedValueUnderflow(); }
       
        // Adjust the gas committed for the next cycle by subtracting the gas amount of the cancelled/stopped task
        if (_isGst) {
            s.registryState.sysGasCommittedForNextCycle = gasCommittedForNextCycle - _maxGasAmount;
        } else {
            s.registryState.gasCommittedForNextCycle = gasCommittedForNextCycle - _maxGasAmount;
        
        }
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: INTERNAL FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Function to update the cycle locked fees and gas committed.
    /// @param _lockedFees Updated cycle locked fees
    /// @param _sysGasCommittedForNextCycle Updated system gas committed for next cycle 
    /// @param _gasCommittedForNextCycle Updated gas committed for next cycle
    /// @param _gasCommittedForNewCycle Updated gas committed for new cycle
    function updateGasCommittedAndCycleLockedFees(
        uint256 _lockedFees,
        uint128 _sysGasCommittedForNextCycle,
        uint128 _gasCommittedForNextCycle,
        uint128 _gasCommittedForNewCycle
    ) internal {
        AppStorage storage s = LibAppStorage.appStorage();

        s.registryState.cycleLockedFees  = _lockedFees;
        s.registryState.sysGasCommittedForNextCycle = _sysGasCommittedForNextCycle;
        s.registryState.sysGasCommittedForThisCycle = _sysGasCommittedForNextCycle;
        s.registryState.gasCommittedForNextCycle = _gasCommittedForNextCycle;
        s.registryState.gasCommittedForThisCycle = _gasCommittedForNewCycle;
    }

    function registerTask(
        bytes memory _payloadTx,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint64 _priority,
        LibCommon.TaskType _taskType,
        bytes[] memory _auxData
    ) internal returns (uint64 taskIndex) {
        AppStorage storage s = LibAppStorage.appStorage();

        uint64 regTime = uint64(block.timestamp);
        bool isUst = _taskType == LibCommon.TaskType.UST;
        uint256 totalTasks = isUst ? s.registryState.taskIdList.length() : s.registryState.sysTaskIds.length();
        
        updateStateForValidRegistration(
            totalTasks,
            regTime,
            _expiryTime,
            _payloadTx,
            _maxGasAmount,
            _gasPriceCap,
            _automationFeeCapForCycle,
            isUst
        );

        taskIndex = createAndStoreTask(
            _payloadTx,
            _expiryTime,
            _maxGasAmount,
            _gasPriceCap,
            _automationFeeCapForCycle,
            _priority,
            _taskType,
            regTime,
            isUst,
            _auxData
        );
    }

    function cancelTask(
        uint64 _taskIndex,
        bool _isGst
    ) internal returns (LibCommon.TaskCancelled memory cancelledTask) {
        AppStorage storage s = LibAppStorage.appStorage();

        TaskMetadata memory task = s.registryState.tasks[_taskIndex];

        validateOwnerType(task.owner, task.taskType, _isGst);
        if (task.taskState == LibCommon.TaskState.CANCELLED) { revert AlreadyCancelled(); }
        if (task.taskState == LibCommon.TaskState.PENDING) {
            LibCommon.removeTask(_taskIndex, task.owner, _isGst);

            // Refund only for UST
            // When Pending tasks are cancelled, refund of the deposit fee is done with penalty
            if (!_isGst) {
                bool result = LibAccounting.safeDepositRefund(
                    _taskIndex,
                    task.owner,
                    task.depositFee / LibAccounting.REFUND_FACTOR,
                    task.depositFee
                );
                if (!result) revert ErrorDepositRefund();
            }
        } else {
            // It is safe not to check the state as above, the cancelled tasks are already rejected.
            // Active tasks will be refunded the deposited amount fully at the end of the cycle.
            s.registryState.tasks[_taskIndex].taskState = LibCommon.TaskState.CANCELLED;
        }

        // This check means the task was expected to be executed in the next cycle, but it has been cancelled.
        // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
        if (task.expiryTime > LibCommon.getCycleEndTime()) {
            updateGasCommittedForNextCycle(_isGst, task.maxGasAmount);
        }

        cancelledTask = LibCommon.TaskCancelled(_taskIndex, task.taskType, task.txHash);
    }

    function stopTask(
        uint64 _taskId,
        uint64 _cycleEndTime,
        bool _isGst
    ) internal returns (LibCommon.TaskStopped memory taskStopped, uint128 refundAmount) {
        AppStorage storage s = LibAppStorage.appStorage();

        TaskMetadata memory task = s.registryState.tasks[_taskId];
        
        validateOwnerType(task.owner, task.taskType, _isGst);

        // Remove task from the registry
        LibCommon.removeTask(_taskId, task.owner, _isGst);
        // Remove from active tasks
        require(s.registryState.activeTaskIds.remove(_taskId), TaskIndexNotFound());

        // This check means the task was expected to be executed in the next cycle, but it has been stopped.
        // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
        // Also it checks that task should not be cancelled.
        if (task.taskState != LibCommon.TaskState.CANCELLED && task.expiryTime > _cycleEndTime) {
            // Reduce committed gas by the stopped task's max gas
            updateGasCommittedForNextCycle(_isGst, task.maxGasAmount);
        }

        uint128 totalRefund;

        if (!_isGst) {
            // Calculate refundable fee for this remaining time task in current cycle
            uint64 currentTime = uint64(block.timestamp);
            uint64 residualInterval = _cycleEndTime <= currentTime ? 0 : (_cycleEndTime - currentTime);

            (uint128 cycleFeeRefund, uint128 depositRefund) = LibAccounting.unlockDepositAndCycleFee(
                _taskId,
                task.taskState,
                task.expiryTime,
                task.maxGasAmount,
                residualInterval,
                currentTime,
                task.depositFee
            );

            totalRefund = cycleFeeRefund + depositRefund;

            taskStopped = LibCommon.TaskStopped(
                _taskId,
                depositRefund,
                cycleFeeRefund,
                task.txHash
            );
        } else {
            taskStopped = LibCommon.TaskStopped(
                _taskId,
                0,
                0,
                task.txHash
            );
        }

        return (taskStopped, totalRefund);
    }
}
