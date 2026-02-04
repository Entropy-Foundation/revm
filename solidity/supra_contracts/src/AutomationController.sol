// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {EnumerableSet} from "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {CommonUtils} from "./CommonUtils.sol";
import {LibController} from "./LibController.sol";

import {IAutomationController} from "./IAutomationController.sol";
import {IAutomationCore} from "./IAutomationCore.sol";
import {IAutomationRegistry} from "./IAutomationRegistry.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";

contract AutomationController is IAutomationController, Ownable2StepUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.UintSet;
    using CommonUtils for *;
    using LibController for *;

    /// @dev State variables
    LibController.AutomationCycleInfo cycleInfo;
    IAutomationRegistry public registry;
    IAutomationCore public automationCore;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: EVENTS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  
    /// @notice Emitted when a task is removed as fee exceeds task's automation fee cap for the cycle.
    event TaskCancelledCapacitySurpassed(
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 fee,
        uint128 automationFeeCapForCycle,
        bytes32 registrationHash
    );

    /// @notice Emitted when a task is removed due to insufficient balance.
    event TaskCancelledInsufficentBalance(
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 fee,
        uint256 balance,
        bytes32 registrationHash
    );

    /// @notice Emitted when an automation fee is charged for an automation task for the cycle.
    event TaskCycleFeeWithdraw(
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 fee
    );

    /// @notice Emitted when the cycle state transitions.
    event AutomationCycleEvent(
        uint64 indexed index,
        CommonUtils.CycleState indexed state,
        uint64 startTime,
        uint64 durationSecs,
        CommonUtils.CycleState indexed oldState
    );

    /// @notice Event emitted on cycle transition containing active task indexes for the new cycle.
    event ActiveTasks(uint256[] indexed taskIndexes);
    
    /// @notice Event emitted on cycle transition containing removed task indexes.
    event RemovedTasks(uint64[] indexed taskIndexes);

    /// @notice Event emitted when on a new cycle inconsistent state of the registry has been identified.
    /// When automation is in suspended state, there are no tasks expected.
    event ErrorInconsistentSuspendedState();

    /// @notice Emitted when the AutomationRegistry contract address is updated.
    event AutomationRegistryUpdated(address indexed oldRegistryAddress, address indexed newRegistryAddress);

    /// @notice Emitted when the AutomationCore contract address is updated.
    event AutomationCoreUpdated(address indexed oldAutomationCore, address indexed newAutomationCore);

    /// @notice Emitted when automation is enabled.
    event AutomationEnabled(bool indexed status);
    
    /// @notice Emitted when automation is disabled.
    event AutomationDisabled(bool indexed status);
    
    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::: CONSTRUCTOR AND INITIALIZER ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }
    
    /// @notice Initializes the configuration parameters of the contract, can only be called once.
    /// @param _automationCore Address of the AutomationCore smart contract.
    /// @param _registry Address of the AutomationRegistry smart contract.
    /// @param _automationEnabled Bool to set automation enabled status.
    function initialize(address _automationCore, address _registry, bool _automationEnabled) public initializer {
        _automationCore.validateContractAddress();
        _registry.validateContractAddress();

        automationCore = IAutomationCore(_automationCore); 
        registry = IAutomationRegistry(_registry);

        (CommonUtils.CycleState state, uint64 cycleId) = _automationEnabled ? (CommonUtils.CycleState.STARTED, 1) : (CommonUtils.CycleState.READY, 0);

        cycleInfo.initializeCycle(
            cycleId,
            uint64(block.timestamp),
            automationCore.cycleDurationSecs(),
            state,
            _automationEnabled
        ); 

        __Ownable2Step_init();
        __Ownable_init(msg.sender);
    }

    /// @notice Called by the VM Signer on `AutomationBookkeepingAction::Process` action emitted by native layer ahead of the cycle transition.
    /// @param _cycleIndex Index of the cycle.
    /// @param _taskIndexes Array of task index to be processed.
    function processTasks(uint64 _cycleIndex, uint64[] memory _taskIndexes) external {
        // Check caller is VM Signer
        if (msg.sender != automationCore.getVmSigner()) { revert CallerNotVmSigner(); }
        
        CommonUtils.CycleState state = cycleInfo.state(); 

        if(state == CommonUtils.CycleState.FINISHED) {
            onCycleTransition(_cycleIndex, _taskIndexes);
        } else {
            if(state != CommonUtils.CycleState.SUSPENDED) { revert InvalidRegistryState(); }
            onCycleSuspend(_cycleIndex, _taskIndexes);
        }
    }

    /// @notice Checks the cycle end and emit an event on it. Does nothing if SUPRA_NATIVE_AUTOMATION or SUPRA_AUTOMATION_V2 is disabled.
    function monitorCycleEnd() external {
        if (tx.origin != automationCore.getVmSigner()) { revert CallerNotVmSigner(); }

        if(!isCycleStarted() || cycleInfo.startTime() + cycleInfo.durationSecs() > block.timestamp) {
            return;
        }
        
        onCycleEndInternal();
    }
    
    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: HELPER FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Traverses the list of the tasks and based on the task state and expiry information either charges or drops the task after refunding eligable fees.
    /// Tasks are checked not to be processed more than once.
    /// This function should be called only if registry is in FINISHED state, meaning a normal cycle transition is happening.
    /// After processing all input tasks, intermediate transition state is updated and transition end is checked (whether all expected tasks has been processed already).
    /// In case if transition end is detected a start of the new cycle is given (if during trasition period suspention is not requested) and corresponding event is emitted.
    /// @param _cycleIndex Cycle index of the new cycle to which the transition is being done.
    /// @param _taskIndexes Array of task indexes to be processed.
    function onCycleTransition(uint64 _cycleIndex, uint64[] memory _taskIndexes) private {
        if(_taskIndexes.length == 0) { return; }

        if(cycleInfo.state() != CommonUtils.CycleState.FINISHED) { revert InvalidRegistryState(); }
        
        // Check if transition state exists
        if(!cycleInfo.ifTransitionStateExists()) { revert InvalidRegistryState(); }
        if(cycleInfo.index() + 1 != _cycleIndex) { revert InvalidInputCycleIndex(); }

        LibController.IntermediateStateOfCycleChange memory intermediateState = dropOrChargeTasks(_taskIndexes);
        
        cycleInfo.transitionState.lockedFees += intermediateState.cycleLockedFees;
        cycleInfo.setGasCommittedForNextCycle(cycleInfo.gasCommittedForNextCycle() + intermediateState.gasCommittedForNextCycle);        
        cycleInfo.setSysGasCommittedForNextCycle(cycleInfo.sysGasCommittedForNextCycle() + intermediateState.sysGasCommittedForNextCycle);
        
        updateCycleTransitionStateFromFinished();
        if(intermediateState.removedTasks.length > 0) {
            emit RemovedTasks(intermediateState.removedTasks);
        }
    }

    /// @notice Traverses the list of the tasks and refunds automation(if not PENDING) and deposit fees for all tasks and removes from registry.
    /// This function is called only if automation feature is disabled, i.e. cycle is in SUSPENDED state.
    /// After processing input set of tasks the end of suspention process is checked(i.e. all expected tasks have been processed).
    /// In case if end is identified, the registry state is update to READY and corresponding event is emitted.
    /// @param _cycleIndex Input cycle index of the cycle being suspended.
    /// @param _taskIndexes Array of task indexes to be processed.
    function onCycleSuspend(uint64 _cycleIndex, uint64[] memory _taskIndexes) private {
        if (_taskIndexes.length == 0) { return; }

        if(cycleInfo.state() != CommonUtils.CycleState.SUSPENDED) { revert InvalidRegistryState(); }
        if(cycleInfo.index() != _cycleIndex) { revert InvalidInputCycleIndex(); }
        // Check if transition state exists
        if(!cycleInfo.ifTransitionStateExists()) { revert InvalidRegistryState(); }

        uint64 currentTime = uint64(block.timestamp);
            
        // Sort task indexes as order is important
        uint64[] memory taskIndexes = _taskIndexes.sortUint64();
        uint64[] memory removedTasks = new uint64[](taskIndexes.length);
        uint64 removedCounter;
        for (uint i = 0; i < taskIndexes.length; i++) {
            if(registry.ifTaskExists(taskIndexes[i])) {
                CommonUtils.TaskDetails memory task = registry.getTaskDetails(taskIndexes[i]);

                (bool removed, ) = address(registry).call(abi.encodeCall(IAutomationRegistry.removeTask, (taskIndexes[i], false)));
                require(removed, RemoveTaskFailed());

                removedTasks[removedCounter++] = taskIndexes[i];
                markTaskProcessed(taskIndexes[i]);

                // Nothing to refund for GST tasks
                if (task.taskType == CommonUtils.TaskType.UST) {                         
                    (bool refunded, ) = address(automationCore).call(
                        abi.encodeCall(
                            IAutomationCore.refundTaskFees, 
                            (currentTime, cycleInfo.refundDuration(), cycleInfo.automationFeePerSec(), task)
                        )
                    );
                    require(refunded, RefundFailed());   
                }
            }
        }
        
        updateCycleTransitionStateFromSuspended();
        emit RemovedTasks(removedTasks);
    }

    /// @notice Traverses all input task indexes and either drops or tries to charge automation fee if possible.
    /// @param _taskIndexes Input task indexes.
    /// @return intermediateState Returns the intermediate state.
    function dropOrChargeTasks(
        uint64[] memory _taskIndexes
    ) private returns (LibController.IntermediateStateOfCycleChange memory intermediateState) { 
        uint64 currentTime = uint64(block.timestamp);
        uint64 currentCycleEndTime = currentTime + cycleInfo.newCycleDuration();

        // Sort task indexes to charge automation fees in their chronological order
        uint64[] memory taskIndexes = _taskIndexes.sortUint64();

        uint64[] memory removedBuffer = new uint64[](taskIndexes.length);
        uint256 removedCount;

        // Process each active task and calculate fee for the cycle for the tasks
        for (uint256 i = 0; i < taskIndexes.length; i++) {
            LibController.TransitionResult memory result = dropOrChargeTask(
                taskIndexes[i],
                currentTime,
                currentCycleEndTime
            );

            if (result.isRemoved) {
                removedBuffer[removedCount] = taskIndexes[i];
                removedCount += 1; 
            }

            intermediateState.gasCommittedForNextCycle += result.gas;
            intermediateState.sysGasCommittedForNextCycle += result.sysGas;
            intermediateState.cycleLockedFees += result.fees;
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
    ) private returns (LibController.TransitionResult memory result){
        if(registry.ifTaskExists(_taskIndex)) {
            markTaskProcessed(_taskIndex);

            CommonUtils.TaskDetails memory task = registry.getTaskDetails(_taskIndex);
            bool isUst = task.taskType == CommonUtils.TaskType.UST;
            
            // Task is cancelled or expired
            if(task.state == CommonUtils.TaskState.CANCELLED || _currentTime >= task.expiryTime) {
                if(isUst) {
                    (bool sent, ) = address(registry).call(
                        abi.encodeCall(
                            IAutomationRegistry.refundDepositAndDrop,
                            (_taskIndex, task.owner, task.lockedFeeForNextCycle, task.lockedFeeForNextCycle)
                        )
                    );
                    require(sent, RefundDepositAndDropFailed());
                } else {
                    // Remove the task from registry and system registry
                    (bool removed, ) = address(registry).call(abi.encodeCall(IAutomationRegistry.removeTask, (_taskIndex, true)));
                    require(removed, RemoveTaskFailed());
                }
                result.isRemoved = true;
            } else if(!isUst) {
                // Active GST
                // Governance submitted tasks are not charged

                result.sysGas = task.maxGasAmount;                
                (bool updated, ) = address(registry).call(abi.encodeCall(IAutomationRegistry.updateTaskState, (_taskIndex, CommonUtils.TaskState.ACTIVE)));
                require(updated, UpdateTaskStateFailed());
            } else {
                // Active UST
                uint128 fee = automationCore.calculateTaskFee(
                    task.state,
                    task.expiryTime,
                    task.maxGasAmount,
                    cycleInfo.newCycleDuration(),
                    _currentTime,
                    cycleInfo.automationFeePerSec()
                );

                // If the task reached this phase that means it is a valid active task for the new cycle.
                // During cleanup all expired tasks has been removed from the registry but the state of the tasks is not updated.
                // As here we need to distinguish new tasks from already existing active tasks,
                // as the fee calculation for them will be different based on their active duration in the cycle.
                // For more details see calculateTaskFee function.
                (bool updated, ) = address(registry).call(abi.encodeCall(IAutomationRegistry.updateTaskState, (_taskIndex, CommonUtils.TaskState.ACTIVE)));
                require(updated, UpdateTaskStateFailed());

                (result.isRemoved, result.gas, result.fees) = tryWithdrawTaskAutomationFee(
                    _taskIndex,
                    task.owner,
                    task.maxGasAmount,
                    task.expiryTime,
                    task.lockedFeeForNextCycle,
                    fee,
                    _currentCycleEndTime,
                    task.automationFeeCapForCycle,
                    task.txHash
                );
            }
        }
    }

    /// @notice Marks a task as processed.
    /// @param _taskIndex Index of the task to be marked as processed.
    function markTaskProcessed(uint64 _taskIndex) private {
        uint64 nextTaskIndexPosition = cycleInfo.nextTaskIndexPosition(); 

        if(nextTaskIndexPosition >= cycleInfo.transitionState.expectedTasksToBeProcessed.length()) { revert InconsistentTransitionState(); }
        uint64 expectedTask = uint64(cycleInfo.transitionState.expectedTasksToBeProcessed.at(nextTaskIndexPosition));

        if(expectedTask != _taskIndex) { revert OutOfOrderTaskProcessingRequest(); } 
        cycleInfo.setNextTaskIndexPosition(nextTaskIndexPosition + 1);  
    }

    /// @notice Helper function to withdraw automation task fees for an active task.
    /// @param _taskIndex Index of the task.
    /// @param _owner Owner of the task.
    /// @param _maxGasAmount Max gas amount of the task.
    /// @param _expiryTime Expiry time of the task.
    /// @param _lockedFeeForNextCycle Locked fees of the task.
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
        uint128 _lockedFeeForNextCycle,
        uint128 _fee,
        uint64 _currentCycleEndTime,
        uint128 _automationFeeCapForCycle,
        bytes32 _regHash
    ) private returns (bool, uint128, uint128) {
        // Remove the automation task if the cycle fee cap is exceeded.
        // It might happen that task has been expired by the time charging is being done.
        // This may be caused by the fact that bookkeeping transactions has been withheld due to cycle transition.
        
        address erc20Supra = automationCore.erc20Supra();
        bool isRemoved;
        uint128 gas;
        uint128 fees;
        if(_fee > _automationFeeCapForCycle) {
            (bool sent, ) = address(registry).call(
                abi.encodeCall(
                    IAutomationRegistry.refundDepositAndDrop, 
                    (_taskIndex, _owner, _lockedFeeForNextCycle,  _lockedFeeForNextCycle)
                )
            );
            require(sent, RefundDepositAndDropFailed());

            isRemoved = true;

            emit TaskCancelledCapacitySurpassed(
                _taskIndex,
                _owner,
                _fee,
                _automationFeeCapForCycle,
                _regHash
            );
        } else {
            uint256 userBalance = IERC20(erc20Supra).balanceOf(_owner);
            if(userBalance < _fee) {
                // If the user does not have enough balance, remove the task, DON'T refund the locked deposit, but simply unlock it and emit an event.

                (bool unlocked, ) = address(automationCore).call(
                    abi.encodeCall(
                        IAutomationCore.safeUnlockLockedDeposit, 
                        (_taskIndex, _lockedFeeForNextCycle)
                    )
                );
                require(unlocked, UnlockLockedDepositFailed());

                (bool removed, ) = address(registry).call(abi.encodeCall(IAutomationRegistry.removeTask, (_taskIndex, false)));
                require(removed, RemoveTaskFailed());
                isRemoved = true;

                emit TaskCancelledInsufficentBalance(
                    _taskIndex,
                    _owner,
                    _fee,
                    userBalance,
                    _regHash
                );
            } else {
                if(_fee != 0)  {
                    // Charge the fee    
                    (bool sent, ) = address(automationCore).call(abi.encodeCall(IAutomationCore.chargeFees, (_owner, _fee)));
                    if (!sent) { revert TransferFailed(); }

                    fees = _fee;
                }
              
                emit TaskCycleFeeWithdraw(
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

    /// @notice Updates the cycle state if the transition is identified to be finalized.
    /// From FINISHED state we always move to the next cycle and in STARTED state.
    /// But if it happened so that there was a suspension during cycle transition which was ignored, then immediately cycle state is updated to suspended.
    /// Expectation will be that native layer catches this double transition and issues refund for the new cycle fees which will not be proceeded further in any case.
    function updateCycleTransitionStateFromFinished() private {
        // Check if transition state exists
        if(!cycleInfo.ifTransitionStateExists()) { revert InvalidRegistryState(); }

        bool transitionFinalized = isTransitionFinalized();
        if (transitionFinalized) {
            if (!cycleInfo.automationEnabled() && cycleInfo.state() == CommonUtils.CycleState.FINISHED) {
                tryMoveToSuspendedState();
            } else {
                (bool updated, ) = address(automationCore).call(
                    abi.encodeCall(
                        IAutomationCore.updateGasCommittedAndCycleLockedFees,
                        (
                            cycleInfo.transitionState.lockedFees,
                            cycleInfo.sysGasCommittedForNextCycle(),
                            cycleInfo.gasCommittedForNextCycle(),
                            cycleInfo.gasCommittedForNewCycle()
                        )
                    )
                );
                require(updated, UpdateGasCommittedAndCycleLockedFeesFailed());
                
                registry.updateTasks(CommonUtils.CycleState.FINISHED);

                // Set current timestamp as cycle start time
                // Increment the cycle and update the state to STARTED
                moveToStartedState();
                if(registry.getTotalActiveTasks() > 0 ) {
                    uint256[] memory activeTasks = registry.getAllActiveTaskIds();
                    emit ActiveTasks(activeTasks);
                }
            }
        }
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
        // Check if transition state exists
        if(!cycleInfo.ifTransitionStateExists()) { revert InvalidRegistryState(); }
        if(!isTransitionFinalized()) {
            return; 
        }
        
        (bool updated, )= address(automationCore).call(abi.encodeCall(IAutomationCore.updateGasCommittedAndCycleLockedFees, (0, 0, 0, 0)));
        require(updated, UpdateGasCommittedAndCycleLockedFeesFailed());

        registry.updateTasks(CommonUtils.CycleState.SUSPENDED);

        // Check if automation is enabled
        if (cycleInfo.automationEnabled()) {
            // Update the config in case if transition flow is STARTED -> SUSPENDED-> STARTED.
            // to reflect new configs for the new cycle if it has been updated during SUSPENDED state processing
            updateConfigFromBuffer();
            moveToStartedState();
        } else {
            moveToReadyState();
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
    function tryMoveToSuspendedState() private {
        if(registry.totalTasks() == 0) {
            // Registry is empty move to ready state directly
            updateCycleStateTo(CommonUtils.CycleState.READY);
        } else if (!cycleInfo.ifTransitionStateExists()) {
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
            uint64 startTime = cycleInfo.startTime(); 
            uint64 cycleDuration = cycleInfo.durationSecs();
            uint64 cycleEndTime = startTime + cycleDuration;

            if(currentTime < startTime) { revert InvalidRegistryState(); }
            if(currentTime >= cycleEndTime) { revert InvalidRegistryState(); }
            if(!isCycleStarted()) { revert InvalidRegistryState(); }

            uint256[] memory expectedTasksToBeProcessed = registry.getTaskIdList().sortUint256();

            cycleInfo.setRefundDuration(cycleEndTime - currentTime);
            cycleInfo.setNewCycleDuration(cycleDuration);
            cycleInfo.setAutomationFeePerSec(automationCore.calculateAutomationFeeMultiplierForCurrentCycleInternal());
            cycleInfo.setGasCommittedForNewCycle(0);
            cycleInfo.setGasCommittedForNextCycle(0);
            cycleInfo.setSysGasCommittedForNextCycle(0);
            cycleInfo.transitionState.lockedFees = 0;
            cycleInfo.setNextTaskIndexPosition(0);

            updateExpectedTasks(expectedTasksToBeProcessed);
            cycleInfo.setTransitionStateExists(true);
            
            updateCycleStateTo(CommonUtils.CycleState.SUSPENDED);
        } else {
            if(cycleInfo.state() != CommonUtils.CycleState.FINISHED) { revert InvalidRegistryState(); }
            if(isTransitionInProgress()) { revert InvalidRegistryState(); }

            // Did not manage to charge cycle fee, so automationFeePerSec will be 0 along with remaining duration
            // So the tasks sent for refund, will get only deposit refunded.  
            cycleInfo.setRefundDuration(0);
            cycleInfo.setAutomationFeePerSec(0);
            cycleInfo.setGasCommittedForNewCycle(0);
            
            updateCycleStateTo(CommonUtils.CycleState.SUSPENDED);
        }
    }

    /// @notice Transitions cycle state to the READY state. 
    function moveToReadyState() private {
        // If the cycle duration updated has been identified during transtion, then the transition state is kept
        // with reset values except new cycle duration to have it properly set for the next new cycle.
        // This may happen in case if cycle was ended and feature-flag has been disbaled before any task has
        // been processed for the cycle transition.
        // Note that we want to have consistent data in ready state which says that the cycle pointed in the ready state
        // has been finished/summerized, and we are ready to start the next new cycle, and all the cycle information should
        // match the finalized/summerized cycle since its start, including cycle duration.

        // Check if transition state exists
        if(cycleInfo.ifTransitionStateExists()) {
            if (cycleInfo.newCycleDuration() == cycleInfo.durationSecs()) {
                // Delete transition state
                cycleInfo.transitionState.expectedTasksToBeProcessed.clear();
                delete cycleInfo.transitionState;
                cycleInfo.setTransitionStateExists(false);
            } else {
                // Reset all except new cycle duration
                cycleInfo.setRefundDuration(0);  
                cycleInfo.setAutomationFeePerSec(0);
                cycleInfo.setGasCommittedForNewCycle(0);
                cycleInfo.setGasCommittedForNextCycle(0);
                cycleInfo.setSysGasCommittedForNextCycle(0);
                cycleInfo.transitionState.lockedFees = 0;
                cycleInfo.setNextTaskIndexPosition(0);
                cycleInfo.transitionState.expectedTasksToBeProcessed.clear();
            }
        }
        updateCycleStateTo(CommonUtils.CycleState.READY);
    }

    /// @notice Transitions cycle state to the STARTED state. 
    function moveToStartedState() private {
        cycleInfo.setIndex(cycleInfo.index() + 1);

        cycleInfo.setStartTime(uint64(block.timestamp));

        // Check if the transition state exists
        if(cycleInfo.ifTransitionStateExists()) {
            cycleInfo.setDurationSecs(cycleInfo.newCycleDuration());
        }

        updateCycleStateTo(CommonUtils.CycleState.STARTED);
    }
    
    /// @notice Updates the state of the cycle.
    /// @param _state Input state to update cycle state with.
    function updateCycleStateTo(CommonUtils.CycleState _state) private {
        CommonUtils.CycleState oldState = cycleInfo.state();
        cycleInfo.setState(uint8(_state));

        emit AutomationCycleEvent (
            cycleInfo.index(),
            cycleInfo.state(),
            cycleInfo.startTime(),
            cycleInfo.durationSecs(),
            oldState
        );
    }

    /// @notice Helper function to update the expected tasks of the transition state.
    function updateExpectedTasks(uint256[] memory _expectedTasks) private {
        cycleInfo.transitionState.expectedTasksToBeProcessed.clear();

        for (uint256 i = 0; i < _expectedTasks.length; i++) {
            cycleInfo.transitionState.expectedTasksToBeProcessed.add(_expectedTasks[i]);
        }
    }

    /// @notice Helper function called when cycle end is identified.
    function onCycleEndInternal() private {
        if (!cycleInfo.automationEnabled()) {
            tryMoveToSuspendedState();
        } else{
            if(registry.totalTasks() == 0) {
                // Registry is empty update config buffer and move to STARTED state directly
                updateConfigFromBuffer();
                moveToStartedState();
            } else {
                uint256[] memory expectedTasksToBeProcessed = registry.getTaskIdList().sortUint256();

                // Updates transition state
                cycleInfo.setRefundDuration(0);
                cycleInfo.setNewCycleDuration(cycleInfo.durationSecs());
                cycleInfo.setGasCommittedForNewCycle(automationCore.getGasCommittedForNextCycle());
                cycleInfo.setGasCommittedForNextCycle(0);
                cycleInfo.setSysGasCommittedForNextCycle (0);
                cycleInfo.transitionState.lockedFees = 0;
                cycleInfo.setNextTaskIndexPosition(0);
                updateExpectedTasks(expectedTasksToBeProcessed);
                
                cycleInfo.setTransitionStateExists(true);

                // During cycle transition we update config only after transition state is created in order to have new cycle duration as transition state parameter.
                updateConfigFromBuffer();

                // Calculate automation fee per second for the new cycle only after configuration is updated.
                // As we already know the committed gas for the new cycle it is being calculated using updated fee parameters
                // and will be used to charge tasks during transition process.
                cycleInfo.setAutomationFeePerSec(automationCore.calculateAutomationFeeMultiplierForCommittedOccupancy(cycleInfo.gasCommittedForNewCycle()));
                updateCycleStateTo(CommonUtils.CycleState.FINISHED);
            }
        }
    }
    
    /// @notice Function to update the registry config structure with values extracted from the buffer, if the buffer exists.
    function updateConfigFromBuffer() private {
        (bool applied, uint64 cycleDuration) = automationCore.applyPendingConfig();
        if (!applied) return;

        // Check if transition state exists
        if (cycleInfo.ifTransitionStateExists()) {
            cycleInfo.setNewCycleDuration(cycleDuration); 
        } else {
            cycleInfo.setDurationSecs(cycleDuration);
        }    
    }

    /// @notice Checks if the cycle transition is finalized.
    /// @return Bool representing if the cycle transition is finalized.
    function isTransitionFinalized() private view returns (bool) {
        return cycleInfo.transitionState.expectedTasksToBeProcessed.length() == cycleInfo.nextTaskIndexPosition();
    }

    /// @notice Checks whether cycle is in STARTED state.
    function isCycleStarted() private view returns (bool) {
        return cycleInfo.state() == CommonUtils.CycleState.STARTED;
    }
    
    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Checks if the cycle transition is in progress.
    /// @return Bool representing if the cycle transition is in progress.
    function isTransitionInProgress() public view returns (bool) {
        return cycleInfo.nextTaskIndexPosition() != 0;
    }
    
    /// @notice Returns the index, start time, duration and state of the current cycle. 
    function getCycleInfo() external view returns (uint64, uint64, uint64, CommonUtils.CycleState) {
        return (cycleInfo.index(), cycleInfo.startTime(), cycleInfo.durationSecs(), cycleInfo.state());
    }

    /// @notice Returns the refund duration and automation fee per sec of the transtition state.
    /// @return Refund duration
    /// @return Automation fee per sec
    function getTransitionInfo() external view returns (uint64, uint128) {
        return (cycleInfo.refundDuration(), cycleInfo.automationFeePerSec());
    }

    /// @notice Returns if automation is enabled.
    function isAutomationEnabled() external view returns (bool) {
        return cycleInfo.automationEnabled();
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ADMIN FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @notice Function to update the AutomationRegistry contract address.
    /// @param _registry Address of the AutomationRegistry contract.
    function setAutomationRegistry(address _registry) external onlyOwner {
        _registry.validateContractAddress();

        address oldRegistry = address(registry);
        registry = IAutomationRegistry(_registry);
        
        emit AutomationRegistryUpdated(oldRegistry, _registry);
    }

    /// @notice Function to update the AutomationCore contract address.
    /// @param _automationCore Address of the AutomationCore contract.
    function setAutomationCore(address _automationCore) external onlyOwner {
        _automationCore.validateContractAddress();
        
        address oldAutomationCore = address(automationCore);
        automationCore = IAutomationCore(_automationCore);
        
        emit AutomationCoreUpdated(oldAutomationCore, _automationCore);
    }

    /// @notice Function to enable the automation.
    function enableAutomation() external onlyOwner {
        if (cycleInfo.automationEnabled()) { revert AlreadyEnabled(); }

        cycleInfo.setAutomationEnabled(true);
        
        if (cycleInfo.state() == CommonUtils.CycleState.READY) {
            moveToStartedState();           
            updateConfigFromBuffer();
        }

        emit AutomationEnabled(cycleInfo.automationEnabled());
    }
    
    /// @notice Function to disable the automation.
    function disableAutomation() external onlyOwner {
        if(!cycleInfo.automationEnabled()) { revert AlreadyDisabled(); }
        
        cycleInfo.setAutomationEnabled(false);

        if (cycleInfo.state() == CommonUtils.CycleState.FINISHED && !isTransitionInProgress()) {
            tryMoveToSuspendedState();
        }

        emit AutomationDisabled(cycleInfo.automationEnabled());
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
