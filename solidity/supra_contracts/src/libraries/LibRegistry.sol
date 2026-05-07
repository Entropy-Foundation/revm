// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {LibAccounting} from "./LibAccounting.sol";
import {LibCommon} from "./LibCommon.sol";
import {LibUtils} from "./LibUtils.sol";
import {AppStorage, Config, LibAppStorage, RegistryState, TaskMetadata} from "./LibAppStorage.sol";
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
    error StaticCallToPredicateFailed();
    error InvalidPayloadLength();
    error InvalidReturnLengthOfPredicate();
    error InvalidReturnTypeOfPredicate();
    
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
        ( , address payloadTarget, bytes memory payload, ) = abi.decode(_payloadTx, (uint128, address, bytes, LibCommon.AccessListEntry[]));
        payloadTarget.validateContractAddress();
        if (payload.length < 4) revert InvalidPayloadLength();
        
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

    /// @notice Validates a predicate by calling it and checking the return value.
    /// @param _predicate Predicate to validate
    function validatePredicate(bytes memory _predicate) private view {
        (address payloadTarget, bytes memory payload) = abi.decode(_predicate, (address, bytes));
        payloadTarget.validateContractAddress();
        if (payload.length < 4) revert InvalidPayloadLength();

        (bool success, bytes memory data) = payloadTarget.staticcall(payload);
        if (!success) revert StaticCallToPredicateFailed();
        if (data.length != 32) revert InvalidReturnLengthOfPredicate();

        uint256 val = abi.decode(data, (uint256));
        if (val > 1) revert InvalidReturnTypeOfPredicate();
    }

    /// @notice Helper function that performs validation and updates state for a valid task.
    function updateStateForValidRegistration(
        uint256 _totalTasks, 
        uint64 _regTime,
        uint64 _expiryTime,
        bytes memory _payloadTx,
        bytes memory _predicate, 
        uint128 _maxGasAmount, 
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        bool _isUst
    ) private {
        AppStorage storage s = LibAppStorage.appStorage();
        Config storage activeConfig = LibAppStorage.activeConfig();
        RegistryState storage registryState = LibAppStorage.registryState();

        // Check if automation and registration is enabled
        if (!s.automationEnabled) { revert AutomationNotEnabled(); }
        if (!s.registrationEnabled) { revert RegistrationDisabled(); }

        if (!LibCommon.isCycleStarted()) { revert CycleTransitionInProgress(); }

        validatePredicate(_predicate);
   
        uint64 taskDurationCap;
        uint128 gasCommittedForNextCycle;
        uint128 nextCycleRegistryMaxGasCap;
        if (_isUst) {
            if (_totalTasks >= activeConfig.taskCapacity) { revert TaskCapacityReached(); }
            if (_gasPriceCap == 0) { revert InvalidGasPriceCap(); }

            gasCommittedForNextCycle = registryState.gasCommittedForNextCycle;
            uint128 estimatedAutomationFeeForCycle = LibAccounting.estimateAutomationFeeWithCommittedOccupancyInternal(_maxGasAmount, gasCommittedForNextCycle);
            if (_automationFeeCapForCycle < estimatedAutomationFeeForCycle) { revert InsufficientFeeCapForCycle(estimatedAutomationFeeForCycle); }
            taskDurationCap = activeConfig.taskDurationCapSecs;
            nextCycleRegistryMaxGasCap = registryState.nextCycleRegistryMaxGasCap;
        } else {
            if (_totalTasks >= activeConfig.sysTaskCapacity) { revert TaskCapacityReached(); }

            gasCommittedForNextCycle = registryState.sysGasCommittedForNextCycle;
            taskDurationCap = activeConfig.sysTaskDurationCapSecs;
            nextCycleRegistryMaxGasCap = registryState.nextCycleSysRegistryMaxGasCap;
        }

        validateTaskDuration(_regTime, _expiryTime, taskDurationCap, s.startTime + s.durationSecs);
        validateInputs(_payloadTx, _maxGasAmount);

        uint128 gasCommitted = _maxGasAmount + gasCommittedForNextCycle;
        if (gasCommitted > nextCycleRegistryMaxGasCap) { revert GasCommittedExceedsMaxGasCap(); }

        if (_isUst) {
            registryState.gasCommittedForNextCycle = gasCommitted;
        } else {
            registryState.sysGasCommittedForNextCycle = gasCommitted;
        } 
    }

    function createAndStoreTask(
        bytes memory _payloadTx,
        bytes memory _predicate,
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
        RegistryState storage registryState = LibAppStorage.registryState();

        taskIndex = registryState.currentIndex;

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
            predicate: _predicate,
            auxData: _auxData
        });
    
        registryState.tasks[taskIndex] = taskMetadata;
        require(registryState.taskIdList.add(taskIndex), TaskIndexNotUnique());
        require(registryState.addressToTasks[msg.sender].add(taskIndex), TaskIndexNotUnique());
    
        if (!_isUst) {
            require(registryState.sysTaskIds.add(taskIndex), TaskIndexNotUnique());
        }
        registryState.currentIndex += 1;
    }

    function reduceGasCommittedForNextCycle(bool _isGst, uint128 _maxGasAmount) private {
        RegistryState storage registryState = LibAppStorage.registryState();

        uint128 gasCommittedForNextCycle = _isGst ? registryState.sysGasCommittedForNextCycle : registryState.gasCommittedForNextCycle;        
        if (gasCommittedForNextCycle < _maxGasAmount) { revert GasCommittedValueUnderflow(); }
       
        // Adjust the gas committed for the next cycle by subtracting the gas amount of the cancelled/stopped task
        if (_isGst) {
            registryState.sysGasCommittedForNextCycle = gasCommittedForNextCycle - _maxGasAmount;
        } else {
            registryState.gasCommittedForNextCycle = gasCommittedForNextCycle - _maxGasAmount;
        
        }
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: INTERNAL FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    function registerTask(
        bytes memory _payloadTx,
        bytes memory _predicate,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint64 _priority,
        LibCommon.TaskType _taskType,
        bytes[] memory _auxData
    ) internal returns (uint64 taskIndex) {
        RegistryState storage registryState = LibAppStorage.registryState();

        uint64 regTime = uint64(block.timestamp);
        bool isUst = _taskType == LibCommon.TaskType.UST;
        uint256 totalTasks = isUst ? registryState.taskIdList.length() : registryState.sysTaskIds.length();
        
        updateStateForValidRegistration(
            totalTasks,
            regTime,
            _expiryTime,
            _payloadTx,
            _predicate,
            _maxGasAmount,
            _gasPriceCap,
            _automationFeeCapForCycle,
            isUst
        );

        taskIndex = createAndStoreTask(
            _payloadTx,
            _predicate,
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
        RegistryState storage registryState = LibAppStorage.registryState();

        TaskMetadata memory task = registryState.tasks[_taskIndex];

        validateOwnerType(task.owner, task.taskType, _isGst);
        if (task.taskState == LibCommon.TaskState.CANCELLED) { revert AlreadyCancelled(); }
        if (task.taskState == LibCommon.TaskState.PENDING) {
            LibCommon.removeTask(_taskIndex, task.owner, _isGst, false);

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
            registryState.tasks[_taskIndex].taskState = LibCommon.TaskState.CANCELLED;
        }

        // This check means the task was expected to be executed in the next cycle, but it has been cancelled.
        // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
        if (task.expiryTime > LibCommon.getCycleEndTime()) {
            reduceGasCommittedForNextCycle(_isGst, task.maxGasAmount);
        }

        cancelledTask = LibCommon.TaskCancelled(_taskIndex, task.taskType, task.txHash);
    }

    function stopTask(
        uint64 _taskId,
        uint64 _cycleEndTime,
        uint64 _currentTime,
        uint64 _residualInterval,
        bool _isGst
    ) internal returns (LibCommon.TaskStopped memory taskStopped, uint128 refund) {
        RegistryState storage registryState = LibAppStorage.registryState();
        TaskMetadata memory task = registryState.tasks[_taskId];
        
        validateOwnerType(task.owner, task.taskType, _isGst);

        (uint128 cycleFeeRefund, uint128 depositRefund) = removeTaskAndComputeRefund(
            _taskId, 
            _cycleEndTime, 
            _currentTime, 
            _residualInterval,
            task.expiryTime,
            task.maxGasAmount,
            task.depositFee,
            task.owner,
            task.taskState,
            _isGst
        );

        refund = cycleFeeRefund + depositRefund;
        taskStopped = LibCommon.TaskStopped(_taskId, depositRefund, cycleFeeRefund, task.txHash);
    }

    function removeTaskAndComputeRefund(
        uint64 _taskId,
        uint64 _cycleEndTime,
        uint64 _currentTime,
        uint64 _residualInterval,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _depositFee,
        address _owner,
        LibCommon.TaskState _taskState,
        bool _isGst
    ) internal returns (uint128 cycleFeeRefund, uint128 depositRefund) {
        // Remove task from the registry and active tasks
        LibCommon.removeTask(_taskId, _owner, _isGst, _taskState != LibCommon.TaskState.PENDING);

        // This check means the task was expected to be executed in the next cycle, but it has been stopped.
        // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
        // Also it checks that task should not be cancelled.
        if (_taskState != LibCommon.TaskState.CANCELLED && _expiryTime > _cycleEndTime) {
            // Reduce committed gas by the stopped task's max gas
            reduceGasCommittedForNextCycle(_isGst, _maxGasAmount);
        }

        if (!_isGst) {
            (cycleFeeRefund, depositRefund) = LibAccounting.unlockDepositAndCycleFee(
                _taskId,
                _taskState,
                _expiryTime,
                _maxGasAmount,
                _residualInterval,
                _currentTime,
                _depositFee
            );
        }
    }
}
