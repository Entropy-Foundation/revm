// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibAccounting} from "./LibAccounting.sol";
import {LibCommon} from "./LibCommon.sol";
import {LibUtils} from "./LibUtils.sol";
import {LibRegistry} from "./LibRegistry.sol";
import {AppStorage, LibAppStorage, RegistryState, TaskMetadata, TransitionState} from "./LibAppStorage.sol";
import {ICoreFacet} from "../interfaces/ICoreFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

library LibCore {
    using LibUtils for address;
    using EnumerableSet for EnumerableSet.UintSet;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: PRIVATE FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Returns the number of total tasks.
    function totalTasks() private view returns (uint256) {
        return LibAppStorage.registryState().taskIdList.length();
    }

    /// @notice Sorts a uint256 array in ascending order using insertion sort.
    /// @dev Insertion sort is chosen here because task ID lists originate from an
    ///      array(near-registry source) whose values are assigned incrementally, so the array is
    ///      nearly-sorted in practice.  For nearly-sorted input, insertion sort runs
    ///      in O(n) time (inner loop exits immediately when the element is already in
    ///      place), making it strictly cheaper in gas than the generic quicksort used
    ///      by OpenZeppelin's Arrays.sort, which cannot exploit existing order.
    ///      The trade-off is worst-case O(n²) on a fully-reversed list, which is
    ///      not a realistic scenario for monotonically-assigned task IDs.
    /// @param arr The memory array to sort in-place.
    /// @return The same memory reference, sorted ascending.
    function insertionSort(uint256[] memory arr) private pure returns (uint256[] memory) {
        // A single-element (or empty) array is trivially sorted.
        for (uint256 i = 1; i < arr.length; i++) {
            uint256 key = arr[i];
            // Walk backwards, shifting elements one position right until we find
            // the correct insertion point for `key`.  We use int256 for `j` to
            // detect the j < 0 boundary without an underflow revert.
            int256 j = int256(i) - 1;
            while (j >= 0 && arr[uint256(j)] > key) {
                arr[uint256(j + 1)] = arr[uint256(j)];
                j--;
            }
            arr[uint256(j + 1)] = key;
        }
        return arr;
    }
    
    /// @notice Returns all the automation tasks available in the registry.
    function getTaskIdList() private view returns (uint256[] memory) {
        return LibAppStorage.registryState().taskIdList.values();
    }

    /// @notice Function to update the cycle locked fees, gas committed and tasks lists.
    /// @param _lockedFees Updated cycle locked fees
    /// @param _sysGasCommittedForNextCycle Updated system gas committed for next cycle 
    /// @param _gasCommittedForNextCycle Updated gas committed for next cycle
    /// @param _gasCommittedForNewCycle Updated gas committed for new cycle
    /// @param _state Cycle transition state executing the update.
    function updateRegistryState(
        uint256 _lockedFees,
        uint128 _sysGasCommittedForNextCycle,
        uint128 _gasCommittedForNextCycle,
        uint128 _gasCommittedForNewCycle,
        LibCommon.CycleState _state
    ) private {
        RegistryState storage registryState = LibAppStorage.registryState();

        registryState.cycleLockedFees  = _lockedFees;
        registryState.sysGasCommittedForNextCycle = _sysGasCommittedForNextCycle;
        registryState.sysGasCommittedForThisCycle = _sysGasCommittedForNextCycle;
        registryState.gasCommittedForNextCycle = _gasCommittedForNextCycle;
        registryState.gasCommittedForThisCycle = _gasCommittedForNewCycle;

        registryState.activeTaskIds.clear();
        if (_state == LibCommon.CycleState.FINISHED) {
            uint256[] memory taskIds = registryState.taskIdList.values();
            for (uint256 i = 0; i < taskIds.length; i++) {
                registryState.activeTaskIds.add(taskIds[i]);
            }
        } else {
            registryState.sysTaskIds.clear();
        }
    }

    /// @notice Function to update the registry configuration with buffered one if exists.
    function applyPendingConfig() private returns (bool, uint64) {
        AppStorage storage s = LibAppStorage.appStorage();

        if (!s.ifBufferExists) {
            return (false, 0);
        } 
        uint64 pendingCycleDuration = LibAppStorage.bufferConfig().cycleDurationSecs;
        s.configuration[LibAppStorage.ACTIVE_CONFIG] = s.configuration[LibAppStorage.BUFFER_CONFIG];
        
        s.ifBufferExists = false;
        delete s.configuration[LibAppStorage.BUFFER_CONFIG];
        
        return (true, pendingCycleDuration);        
    }

    /// @notice Updates the state of the cycle.
    /// @param _state Input state to update cycle state with.
    function updateCycleStateTo(LibCommon.CycleState _state) private {
        AppStorage storage s = LibAppStorage.appStorage();

        LibCommon.CycleState oldState = s.cycleState;
        s.cycleState = _state;

        emit ICoreFacet.AutomationCycleEvent (
            s.index,
            s.cycleState,
            s.startTime,
            s.durationSecs,
            oldState
        );
    }

    /// @notice Helper function to update the expected tasks of the transition state.
    /// @dev A direct storage-array assignment from `_expectedTasks` both clears any
    ///      previous contents (the compiler zeroes out any leftover tail elements if
    ///      the new list is shorter) and writes the new elements in a single pass —
    ///      one SSTORE per task, field is ever read sequentially(see the declaration)
    function updateExpectedTasks(uint256[] memory _expectedTasks) private {
        LibAppStorage.transitionState().expectedTasksToBeProcessed = _expectedTasks;
    }

    /// @notice Transitions cycle state to the READY state. 
    function moveToReadyState() private {
        // If the cycle duration updated has been identified during transition, then the transition state is kept
        // with reset values except new cycle duration to have it properly set for the next new cycle.
        // This may happen in case if cycle was ended and feature-flag has been disabled before any task has
        // been processed for the cycle transition.
        // Note that we want to have consistent data in ready state which says that the cycle pointed in the ready state
        // has been finished/summerized, and we are ready to start the next new cycle, and all the cycle information should
        // match the finalized/summerized cycle since its start, including cycle duration.

        AppStorage storage s = LibAppStorage.appStorage();
        TransitionState storage transitionState = LibAppStorage.transitionState();

        // Check if transition state exists
        if (s.ifTransitionStateExists) {
            if (transitionState.newCycleDuration == s.durationSecs) {
                // Delete transition state. Deleting the whole struct already recursively
                // clears expectedTasksToBeProcessed since it is a plain dynamic array
                delete s.transitionState[LibAppStorage.TRANSITION_STATE];
                s.ifTransitionStateExists = false;
            } else {
                // Reset all except new cycle duration
                transitionState.refundDuration = 0;
                transitionState.automationFeePerSec = 0;
                transitionState.gasCommittedForNewCycle = 0;
                transitionState.gasCommittedForNextCycle = 0;
                transitionState.sysGasCommittedForNextCycle = 0;
                transitionState.lockedFees = 0;
                transitionState.nextTaskIndexPosition = 0;
                delete transitionState.expectedTasksToBeProcessed;
            }
        }
        updateCycleStateTo(LibCommon.CycleState.READY);
    }

    /// @notice Updates the cycle state if the transition is identified to be finalized.
    /// As transition happens from suspended state and while transition was in progress
    ///    - if the feature was enabled back, then the transition will happen direclty to STARTED state,
    ///    - otherwise the transition will be done to the READY state.
    ///
    /// In both cases config will be updated. In this case we will make sure to keep the consistency of state
    /// when transition to READY state happens through paths
    ///  - Started -> Suspended -> Ready
    ///  - or Started-> {Finished, Suspended} -> Ready
    ///  - or Started -> Finished -> {Started, Suspended}
    function updateCycleTransitionStateFromSuspended() private {
        AppStorage storage s = LibAppStorage.appStorage();

        // Check if transition state exists
        if (!s.ifTransitionStateExists) { revert ICoreFacet.InvalidRegistryState(); }
        if (!isTransitionFinalized()) {
            return; 
        }
        
        updateRegistryState(0, 0, 0, 0, LibCommon.CycleState.SUSPENDED);

        // Check if automation is enabled
        if (s.automationEnabled) {
            // Update the config in case if transition flow is STARTED -> SUSPENDED-> STARTED.
            // to reflect new configs for the new cycle if it has been updated during SUSPENDED state processing
            updateConfigFromBuffer();
            moveToStartedState();
        } else {
            moveToReadyState();
        }
    }

    /// @notice Marks a task as processed.
    /// @param _taskIndex Index of the task to be marked as processed.
    function markTaskProcessed(uint64 _taskIndex) private {
        TransitionState storage transitionState = LibAppStorage.transitionState();

        uint64 nextTaskIndexPosition = transitionState.nextTaskIndexPosition;

        if (nextTaskIndexPosition >= transitionState.expectedTasksToBeProcessed.length) { revert ICoreFacet.InconsistentTransitionState(); }
        uint64 expectedTask = uint64(transitionState.expectedTasksToBeProcessed[nextTaskIndexPosition]);

        if (expectedTask != _taskIndex) { revert ICoreFacet.OutOfOrderTaskProcessingRequest(); } 
        transitionState.nextTaskIndexPosition = nextTaskIndexPosition + 1;  
    }

    /// @notice Updates the cycle state if the transition is identified to be finalized.
    /// From FINISHED state we always move to the next cycle in STARTED state first (incrementing cycle index).
    /// If automation was disabled during the transition, we immediately initiate suspension from the new STARTED state.
    /// This ensures cycle index is always incremented before suspension, and a fresh suspension transition is set up.
    function updateCycleTransitionStateFromFinished() private {
        AppStorage storage s = LibAppStorage.appStorage();

        // Check if transition state exists
        if (!s.ifTransitionStateExists) { revert ICoreFacet.InvalidRegistryState(); }

        if (isTransitionFinalized()) {
            TransitionState storage transitionState = LibAppStorage.transitionState();
            updateRegistryState(
                transitionState.lockedFees,
                transitionState.sysGasCommittedForNextCycle,
                transitionState.gasCommittedForNextCycle,
                transitionState.gasCommittedForNewCycle,
                LibCommon.CycleState.FINISHED
            );

            // Set current timestamp as cycle start time
            // Increment the cycle and update the state to STARTED
            moveToStartedState();

            RegistryState storage registryState = LibAppStorage.registryState();
            if (registryState.activeTaskIds.length() > 0 ) {
                uint256[] memory activeTasks = registryState.activeTaskIds.values();
                emit ICoreFacet.ActiveTasks(activeTasks);
            }
            if (!s.automationEnabled) {
                tryMoveToSuspendedState();
            }
        }
    }

    /// @notice Traverses all input task indexes and either drops or tries to charge automation fee if possible.
    /// @param _taskIndexes Input task indexes.
    /// @return intermediateState Returns the intermediate state.
    function dropOrChargeTasks(
        uint256[] memory _taskIndexes
    ) private returns (LibCommon.IntermediateStateOfCycleChange memory intermediateState) {
        uint64 currentTime = uint64(block.timestamp);
        uint64 currentCycleEndTime = currentTime + LibAppStorage.transitionState().newCycleDuration;

        // Sort task indexes to charge automation fees in their chronological order
        uint256[] memory taskIndexes = insertionSort(_taskIndexes);

        uint64[] memory removedBuffer = new uint64[](taskIndexes.length);
        uint256 removedCount;

        // Process each active task and calculate fee for the cycle for the tasks
        for (uint256 i = 0; i < taskIndexes.length; i++) {
            uint64 taskId = uint64(taskIndexes[i]); 
            LibCommon.TransitionResult memory result = dropOrChargeTask(
                taskId,
                currentTime,
                currentCycleEndTime
            );

            if (result.isRemoved) {
                removedBuffer[removedCount] = taskId;
                removedCount += 1; 
            } else {
                intermediateState.gasCommittedForNextCycle += result.gas;
                intermediateState.sysGasCommittedForNextCycle += result.sysGas;
                intermediateState.cycleLockedFees += result.fees;
            }
        }

        uint64[] memory removedTasks = new uint64[](removedCount);
        for (uint256 j = 0; j < removedCount; j++) {
            removedTasks[j] = removedBuffer[j];
        }
        intermediateState.removedTasks = removedTasks;
    }

    /// @notice Drops or charges the input task. If the task is already processed or missing from the registry then nothing is done.
    /// @param _taskIndex Task index to be dropped or charged.
    /// @param _currentTime Current time.
    /// @param _currentCycleEndTime End time of the current cycle.
    /// @return result Returns the TransitionResult.
    function dropOrChargeTask(
        uint64 _taskIndex,
        uint64 _currentTime,
        uint64 _currentCycleEndTime
    ) private returns (LibCommon.TransitionResult memory result) {
        if (LibCommon.ifTaskExists(_taskIndex)) {
            markTaskProcessed(_taskIndex);

            TaskMetadata memory task = LibCommon.getTask(_taskIndex);
            bool isUst = task.taskType == LibCommon.TaskType.UST;
            
            RegistryState storage registryState = LibAppStorage.registryState();
            
            // Task is cancelled or expired
            if (task.taskState == LibCommon.TaskState.CANCELLED || _currentTime >= task.expiryTime) {
                if (isUst) {
                    LibAccounting.refundDepositAndDrop(_taskIndex, task.owner, task.depositFee, task.depositFee);
                } else {
                    // Remove the task from registry and system registry
                    LibCommon.removeTask(_taskIndex, task.owner, true, false);
                }
                result.isRemoved = true;
            } else if (!isUst) {
                // Active GST
                // Governance submitted tasks are not charged

                if (task.expiryTime > _currentCycleEndTime) {
                    result.sysGas = task.maxGasAmount;
                }
                registryState.tasks[_taskIndex].taskState = LibCommon.TaskState.ACTIVE;
            } else {
                TransitionState storage transitionState = LibAppStorage.transitionState();
                // Active UST
                uint128 fee = LibAccounting.calculateTaskFee(
                    task.taskState,
                    task.expiryTime,
                    task.maxGasAmount,
                    transitionState.newCycleDuration,
                    _currentTime,
                    transitionState.automationFeePerSec
                );

                // If the task reached this phase that means it is a valid active task for the new cycle.
                // During cleanup all expired tasks has been removed from the registry but the state of the tasks is not updated.
                // As here we need to distinguish new tasks from already existing active tasks,
                // as the fee calculation for them will be different based on their active duration in the cycle.
                // For more details see calculateTaskFee function.
                
                registryState.tasks[_taskIndex].taskState = LibCommon.TaskState.ACTIVE;
                (result.isRemoved, result.gas, result.fees) = tryWithdrawTaskAutomationFee(
                    _taskIndex,
                    task.owner,
                    task.maxGasAmount,
                    task.expiryTime,
                    task.depositFee,
                    fee,
                    _currentCycleEndTime,
                    task.automationFeeCapForCycle,
                    task.txHash
                );
            }
        }
    }

    /// @notice Helper function to withdraw automation task fees for an active task.
    /// @param _taskIndex Index of the task.
    /// @param _owner Owner of the task.
    /// @param _maxGasAmount Max gas amount of the task.
    /// @param _expiryTime Expiry time of the task.
    /// @param _depositRefund Deposit refund of the task.
    /// @param _fee Fees to be charged for the task. 
    /// @param _currentCycleEndTime End time of the current cycle.
    /// @param _automationFeeCapForCycle Max automation fee for a cycle to be paid.
    /// @param _regHash Tx hash of the task.
    /// @return Bool representing if the task was removed.
    /// @return Amount to add to gasCommittedForNextCycle 
    /// @return Amount to add to cycleLockedFees 
    function tryWithdrawTaskAutomationFee(
        uint64 _taskIndex,
        address _owner,
        uint128 _maxGasAmount,
        uint64 _expiryTime,
        uint128 _depositRefund,
        uint128 _fee,
        uint64 _currentCycleEndTime,
        uint128 _automationFeeCapForCycle,
        bytes32 _regHash
    ) private returns (bool, uint128, uint128) {
        AppStorage storage s = LibAppStorage.appStorage();

        // Remove the automation task if the cycle fee cap is exceeded.
        // It might happen that task has been expired by the time charging is being done.
        // This may be caused by the fact that bookkeeping transactions has been withheld due to cycle transition.
        
        bool isRemoved;
        uint128 gas;
        uint128 fees;
        if (_fee > _automationFeeCapForCycle) {
            LibAccounting.refundDepositAndDrop(_taskIndex, _owner, _depositRefund, _depositRefund);

            isRemoved = true;

            emit ICoreFacet.TaskCancelledCapacitySurpassed(
                _taskIndex,
                _owner,
                _fee,
                _automationFeeCapForCycle,
                _regHash
            );
        } else {
            address erc20Supra = s.erc20Supra;
            uint256 userBalance = IERC20(erc20Supra).balanceOf(_owner);
            uint256 allowance = IERC20(erc20Supra).allowance(_owner, address(this));
            
            if (userBalance < _fee || allowance < _fee) {
                // If the user hasn't granted enough allowance or if they don't have enough balance, remove the task.
                // DON'T refund the locked deposit, but simply unlock it and emit an event.

                LibAccounting.safeUnlockLockedDeposit(_taskIndex, _depositRefund);
                LibCommon.removeTask(_taskIndex, _owner, false, false);

                isRemoved = true;

                emit ICoreFacet.TaskCancelledInsufficentBalanceAllowance(
                    _taskIndex,
                    _owner,
                    _fee,
                    userBalance,
                    allowance,
                    _regHash
                );
            } else {
                if (_fee != 0)  {
                    // Charge the fee    
                    bool sent = IERC20(erc20Supra).transferFrom(_owner, address(this), _fee);
                    if (!sent) { revert ICoreFacet.TransferFailed(); }

                    fees = _fee;
                }
              
                emit ICoreFacet.TaskCycleFeeWithdraw(
                    s.index,
                    _taskIndex,
                    _owner,
                    _fee
                );

                // Calculate gas commitment for the next cycle only for valid active tasks
                if (_expiryTime > _currentCycleEndTime) {
                    gas = _maxGasAmount;
                }
            }
        }

        return (isRemoved, gas, fees);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: INTERNAL FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Checks if the cycle transition is finalized.
    /// @return Bool representing if the cycle transition is finalized.
    function isTransitionFinalized() internal view returns (bool) {
        TransitionState storage transitionState = LibAppStorage.transitionState();
        return transitionState.expectedTasksToBeProcessed.length == transitionState.nextTaskIndexPosition;
    }

    /// @notice Checks if the cycle transition is in progress.
    /// @return Bool representing if the cycle transition is in progress.
    function isTransitionInProgress() internal view returns (bool) {
        return LibAppStorage.transitionState().nextTaskIndexPosition != 0;
    }

    /// @notice Traverses the list of the tasks and based on the task state and expiry information either charges or drops the task after refunding eligable fees.
    /// Tasks are checked not to be processed more than once.
    /// This function should be called only if registry is in FINISHED state, meaning a normal cycle transition is happening.
    /// After processing all input tasks, intermediate transition state is updated and transition end is checked (whether all expected tasks has been processed already).
    /// In case if transition end is detected a start of the new cycle is given (if during trasition period suspention is not requested) and corresponding event is emitted.
    /// @param _cycleIndex Cycle index of the new cycle to which the transition is being done.
    /// @param _taskIndexes Array of task indexes to be processed.
    function onCycleTransition(uint64 _cycleIndex, uint256[] memory _taskIndexes) internal {
        AppStorage storage s = LibAppStorage.appStorage();

        if (s.cycleState != LibCommon.CycleState.FINISHED) { revert ICoreFacet.InvalidRegistryState(); }
        
        // Check if transition state exists
        if (!s.ifTransitionStateExists) { revert ICoreFacet.InvalidRegistryState(); }
        if (s.index + 1 != _cycleIndex) { revert ICoreFacet.InvalidInputCycleIndex(); }

        LibCommon.IntermediateStateOfCycleChange memory intermediateState = dropOrChargeTasks(_taskIndexes);
        
        TransitionState storage transitionState = LibAppStorage.transitionState();
        transitionState.lockedFees += intermediateState.cycleLockedFees;
        transitionState.gasCommittedForNextCycle += intermediateState.gasCommittedForNextCycle;        
        transitionState.sysGasCommittedForNextCycle += intermediateState.sysGasCommittedForNextCycle;

        updateCycleTransitionStateFromFinished();
        if (intermediateState.removedTasks.length > 0) {
            emit ICoreFacet.RemovedTasks(intermediateState.removedTasks);
        }
    }

    /// @notice Traverses the list of the tasks and refunds automation(if not PENDING) and deposit fees for all tasks and removes from registry.
    /// This function is called only if automation feature is disabled, i.e. cycle is in SUSPENDED state.
    /// After processing input set of tasks the end of suspention process is checked(i.e. all expected tasks have been processed).
    /// In case if end is identified, the registry state is update to READY and corresponding event is emitted.
    /// @param _cycleIndex Input cycle index of the cycle being suspended.
    /// @param _taskIndexes Array of task indexes to be processed.
    function onCycleSuspend(uint64 _cycleIndex, uint256[] memory _taskIndexes) internal {
        AppStorage storage s = LibAppStorage.appStorage();

        if (s.cycleState != LibCommon.CycleState.SUSPENDED) { revert ICoreFacet.InvalidRegistryState(); }
        if (s.index != _cycleIndex) { revert ICoreFacet.InvalidInputCycleIndex(); }
        // Check if transition state exists
        if (!s.ifTransitionStateExists) { revert ICoreFacet.InvalidRegistryState(); }

        uint64 currentTime = uint64(block.timestamp);
            
        // Sort task indexes as order is important
        uint256[] memory taskIndexes = insertionSort(_taskIndexes);
        uint64[] memory removedTasks = new uint64[](taskIndexes.length);
        
        uint64 removedCounter;
        for (uint i = 0; i < taskIndexes.length; i++) {
            uint64 taskId = uint64(taskIndexes[i]);
            if (LibCommon.ifTaskExists(taskId)) {
                TaskMetadata memory task = LibCommon.getTask(taskId);

                LibCommon.removeTask(taskId, task.owner, false, false);

                removedTasks[removedCounter++] = taskId;
                markTaskProcessed(taskId);

                // Nothing to refund for GST tasks
                if (task.taskType == LibCommon.TaskType.UST) {
                    TransitionState storage transitionState = LibAppStorage.transitionState();
                    LibAccounting.refundTaskFees(
                        currentTime, 
                        transitionState.refundDuration, 
                        transitionState.automationFeePerSec, 
                        task
                    );
                }
            }
        }
        
        updateCycleTransitionStateFromSuspended();
        emit ICoreFacet.RemovedTasks(removedTasks);
    }

    /// @notice Removes a registered task when predicate validation fails during runtime.
    /// @param _taskId Task index that failed predicate validation.
    /// @param _cycleEndTime Cycle end time.
    /// @param _currentTime Current time.
    /// @param _residualInterval Residual interval.
    /// @param _reason Reason for task removal.
    function handleTasksRemoval(
        uint64 _taskId, 
        uint64 _cycleEndTime, 
        uint64 _currentTime, 
        uint64 _residualInterval,
        string memory _reason
    ) internal returns (LibCommon.RemovedTask memory removedTask) {
        RegistryState storage registryState = LibAppStorage.registryState();
            
        TaskMetadata memory task = registryState.tasks[_taskId];
        bool isGst = task.taskType == LibCommon.TaskType.GST;

        (uint128 cycleFeeRefund, uint128 depositRefund) = LibRegistry.removeTaskAndComputeRefund(
            _taskId, 
            _cycleEndTime, 
            _currentTime, 
            _residualInterval,
            task.expiryTime,
            task.maxGasAmount,
            task.depositFee,
            task.owner,
            task.taskState,
            isGst
        );
        
        if (!isGst) {
            LibAccounting.refund(task.owner, (cycleFeeRefund + depositRefund));
        }

        removedTask = LibCommon.RemovedTask(_taskId, task.taskType, task.owner, task.txHash, _reason);
    }

    /// @notice Helper function called when cycle end is identified.
    function onCycleEndInternal() internal {
        AppStorage storage s = LibAppStorage.appStorage();

        if (!s.automationEnabled) {
            tryMoveToSuspendedState();
        } else {
            if (totalTasks() == 0) {
                // Registry is empty update config buffer and move to STARTED state directly
                updateConfigFromBuffer();
                moveToStartedState();
            } else {
                // insertionSort is used here instead of Arrays.sort because task IDs are
                // assigned incrementally and the list is nearly-sorted — see insertionSort NatSpec.
                uint256[] memory expectedTasksToBeProcessed = insertionSort(getTaskIdList());

                // Updates transition state
                TransitionState storage transitionState = LibAppStorage.transitionState();

                transitionState.refundDuration = 0;
                transitionState.newCycleDuration = s.durationSecs;
                transitionState.gasCommittedForNewCycle = LibAppStorage.registryState().gasCommittedForNextCycle;
                transitionState.gasCommittedForNextCycle = 0;
                transitionState.sysGasCommittedForNextCycle = 0;
                transitionState.lockedFees = 0;
                transitionState.nextTaskIndexPosition = 0;
                updateExpectedTasks(expectedTasksToBeProcessed);

                s.ifTransitionStateExists = true;

                // During cycle transition we update config only after transition state is created in order to have new cycle duration as transition state parameter.
                updateConfigFromBuffer();

                // Calculate automation fee per second for the new cycle only after configuration is updated.
                // As we already know the committed gas for the new cycle it is being calculated using updated fee parameters
                // and will be used to charge tasks during transition process.
                transitionState.automationFeePerSec = LibAccounting.calculateAutomationFeeMultiplierForCommittedOccupancy(transitionState.gasCommittedForNewCycle);
                updateCycleStateTo(LibCommon.CycleState.FINISHED);
            }
        }
    }

    /// @notice Transition to suspended state is expected to be called
    ///   a) when cycle is active and in progress
    ///     - here we simply move to suspended state so native layer can start requesting tasks processing
    ///       which will end up in refunds and cleanup. Note that refund will be done based on total gas-committed
    ///       for the current cycle defined at the begining for the cycle, and using current automation fee parameters
    ///   b) when cycle has just finished and there was another transaction causing feature suspension
    ///     - as this both events happen in scope of the same block, then we will simply update the state to suspended
    ///       and the native layer should identify the transition and request processing of the all available tasks.
    ///       Note that in this case automation fee refund will not be expected and suspention and cycle end matched and
    ///       no fee was yet charged to be refunded.
    ///       So the duration for refund and automation-fee-per-second for refund will be 0
    ///   c) when cycle transition was in progress and there was a feature suspension, but it could not be applied,
    ///      and postponed till the cycle transition concludes
    /// In all the cases if there are no tasks in registry the state will be updated directly to READY state.
    function tryMoveToSuspendedState() internal {
        AppStorage storage s = LibAppStorage.appStorage();
        TransitionState storage transitionState = LibAppStorage.transitionState();
        
        if (totalTasks() == 0) {
            // Registry is empty move to ready state directly
            updateCycleStateTo(LibCommon.CycleState.READY);
        } else if (!s.ifTransitionStateExists) {
            // Indicates that cycle was in STARTED state when suspention has been identified.
            // It is safe to assert that cycleEndTime will always be greater than current chain time as
            // the cycle end is check in the block metadata txn execution which proceeds any other transaction in the block.
            // Including the transaction which caused transition to suspended state.
            // So in case if cycleEndTime < currentTime then cycle end would have been identified
            // and we would have enterend else branch instead.
            // This holds true even if we identified suspention when moving from FINALIZED->STARTED state.
            // As in this case we will first transition to the STARTED state and only then to SUSPENDED.
            // And when transition to STARTED state we update the cycle start-time to be the current-chain-time.
            uint64 currentTime = uint64(block.timestamp); 
            uint64 cycleEndTime = LibCommon.getCycleEndTime();

            if (currentTime < s.startTime) { revert ICoreFacet.InvalidRegistryState(); }
            if (currentTime >= cycleEndTime) { revert ICoreFacet.InvalidRegistryState(); }
            if (!LibCommon.isCycleStarted()) { revert ICoreFacet.InvalidRegistryState(); }

            uint256[] memory tasksIdList = getTaskIdList();
            uint256[] memory expectedTasksToBeProcessed = insertionSort(tasksIdList);

            transitionState.refundDuration = cycleEndTime - currentTime;
            transitionState.newCycleDuration = s.durationSecs;
            transitionState.automationFeePerSec = LibAccounting.calculateAutomationFeeMultiplierForCurrentCycle();
            transitionState.gasCommittedForNewCycle = 0;
            transitionState.gasCommittedForNextCycle = 0;
            transitionState.sysGasCommittedForNextCycle = 0;
            transitionState.lockedFees = 0;
            transitionState.nextTaskIndexPosition = 0;

            updateExpectedTasks(expectedTasksToBeProcessed);
            s.ifTransitionStateExists = true;
            
            updateCycleStateTo(LibCommon.CycleState.SUSPENDED);
        } else {
            if (s.cycleState != LibCommon.CycleState.FINISHED) { revert ICoreFacet.InvalidRegistryState(); }
            if (isTransitionInProgress()) { revert ICoreFacet.InvalidRegistryState(); }
            
            // Did not manage to charge cycle fee, so automationFeePerSec will be 0 along with remaining duration
            // So the tasks sent for refund, will get only deposit refunded.  
            transitionState.refundDuration = 0;
            transitionState.automationFeePerSec = 0;
            transitionState.gasCommittedForNewCycle = 0;
            
            updateCycleStateTo(LibCommon.CycleState.SUSPENDED);
        }
    }

    /// @notice Transitions cycle state to the STARTED state. 
    function moveToStartedState() internal {
        AppStorage storage s = LibAppStorage.appStorage();
        
        s.index += 1;
        s.startTime = uint64(block.timestamp);

        // Check if the transition state exists
        if (s.ifTransitionStateExists) {
            s.durationSecs = LibAppStorage.transitionState().newCycleDuration;
            s.ifTransitionStateExists = false;
        }

        updateCycleStateTo(LibCommon.CycleState.STARTED);
    }

    /// @notice Function to update the registry config structure with values extracted from the buffer, if the buffer exists.
    function updateConfigFromBuffer() internal {
        AppStorage storage s = LibAppStorage.appStorage();

        (bool applied, uint64 cycleDuration) = applyPendingConfig();
        if (!applied) return;

        // Check if transition state exists
        if (s.ifTransitionStateExists) {
            LibAppStorage.transitionState().newCycleDuration = cycleDuration; 
        } else {
            s.durationSecs = cycleDuration;
        }    
    }
}
