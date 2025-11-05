// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AutomationStorage} from "./AutomationStorage.sol";
import {EnumerableSet} from "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {IAutomationController} from "./IAutomationController.sol";
import {IAutomationRegistry} from "./IAutomationRegistry.sol";
import {Ownable2StepUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";

contract AutomationController is IAutomationController, Ownable2StepUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using AutomationStorage for *;

    /// @dev Constants describing REFUND TYPE
    uint8 constant DEPOSIT_EPOCH_FEE = 0;
    uint8 constant EPOCH_FEE = 1;


    AutomationStorage.AutomationCycleInfo internal cycleInfo;
    // AutomationStorage.TransitionState private transitionState;
    IAutomationRegistry registry;

    event ErrorInsufficientBalanceToRefund(
        uint64 _taskIndex,
        address _owner,
        uint8 _refundType,
        uint128 _amount
    );
    event ErrorUnlockTaskDepositFee(uint64 indexed taskIndex, uint256 totalDepositedAutomationFees, uint128 lockedDeposit);
    event TaskDepositFeeRefund(uint64 indexed taskIndex, address owner, uint128 amount);
    event TaskCancelledCapacitySurpassedV2(
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 fee,
        uint128 automationFeeCapForCycle,
        bytes32 registrationHash
    );
    event TaskCancelledInsufficentBalanceV2(
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 fee,
        uint256 balance,
        bytes32 registration_hash
    );
    event TaskCycleFeeWithdraw(
        uint64 taskIndex,
        address owner,
        uint128 fee
    );

    
    
    /// @dev Disables the initialization for implementation contract.
    constructor() {
        _disableInitializers();
    }
    
    /// @notice Initializes the configuration parameters of the contract, can only be called once.
    /// @param _registry Address of the registry smart contract.
    function initialize(address _registry) public initializer {
        registry = IAutomationRegistry(_registry);

        __Ownable2Step_init();
        __Pausable_init();
    }


    function markTaskProcessed(uint64 _taskIndex) internal {
        if(cycleInfo.transitionState.nextTaskIndexPosition >= EnumerableSet.length(cycleInfo.transitionState.expectedTasksToBeProcessed)) { revert InconsistentTransitionState(); }
        uint64 expectedTask = uint64(EnumerableSet.at(cycleInfo.transitionState.expectedTasksToBeProcessed, cycleInfo.transitionState.nextTaskIndexPosition));

        if(expectedTask != _taskIndex) { revert OutOfOrderTaskProcessingRequest(); } 
        cycleInfo.transitionState.nextTaskIndexPosition += 1;
    }

    /// Unlocks the deposit paid by the task from internal deposit refund bookkeeping state.
    /// Error event is emitted if the deposit refund bookkeeping state is inconsistent with the requested unlock amount.
    function safe_unlock_locked_deposit(
        uint64 _taskIndex,
        uint128 _lockedDeposit
    ) internal returns (bool) {
        uint256 totalDepositedAutomationFees = registry.getTotalDepositedAutomationFees();
        bool hasLockedDeposit = totalDepositedAutomationFees >= _lockedDeposit;
        
        if(hasLockedDeposit) {
            registry.updateTotalDepositedAutomationFees(totalDepositedAutomationFees - _lockedDeposit);
        } else {
            emit ErrorUnlockTaskDepositFee(_taskIndex, totalDepositedAutomationFees, _lockedDeposit);
        }

        return hasLockedDeposit;
    }


    /// Refunds specified amount to the task owner.
    /// Error event is emitted if the resource account does not have enough balance.
    function safe_refund(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableAmount,
        uint8 _refundType
    ) internal returns (bool) {
        uint256 balance = address(registry).balance;
        if(balance < _refundableAmount) {
            emit ErrorInsufficientBalanceToRefund(_taskIndex, _taskOwner, _refundType, _refundableAmount);
            return false;
        } else {
            (bool sent, )= payable(_taskOwner).call{value: _refundableAmount}("");
            if(!sent) { revert TransferFailed(); }
            
            return sent;
        }
    }

    ///   - if the full deposit can not be unlocked.
    function safe_deposit_refund(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) internal returns (bool) {
        // This check will make sure that no more than totally locked deposited will be refunded.
        // If there is an attempt then it means implementation bug.
        bool result = safe_unlock_locked_deposit(_taskIndex, _lockedDeposit);
        if (!result) {
            return result;
        }

        result = safe_refund( _taskIndex, _taskOwner, _refundableDeposit, DEPOSIT_EPOCH_FEE);

        if (result) { emit TaskDepositFeeRefund(_taskIndex, _taskOwner, _refundableDeposit); }
        return result;
    }

    /// Refunds the deposit fee of the task and removes from registry.
    function refund_deposit_and_drop(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) internal {
        // remove task
        registry.removeTask(_taskIndex);

        // TO_DO: check task type is UST

        // refund
        safe_deposit_refund(
            _taskIndex,
            _taskOwner,
            _refundableDeposit,
            _lockedDeposit
        );
        // TO_DO: add to removed
    }

    /// Removes system task from registry state.
    function drop_system_task(
        uint64 _taskIndex
    ) internal {
        // TO_DO: check task is GST

        // remove task from mapping
        registry.removeTask(_taskIndex);
        
        // remove system task
        registry.removeSysTask(_taskIndex);
    }


    /// Calculates automation task fees for a single task at the time of new epoch.
    /// This is supposed to be called only after removing expired task and must not be called for expired task.
    /// It returns calculated task fee for the interval the task will be active.
    function calculate_task_fee(
        AutomationStorage.TaskState _state,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _potentialFeeTimeframe,
        uint64 _currentTime,
        uint128 _automationFeePerSec,
        uint128 _registryMaxGasCap
    ) internal view returns (uint128) {
        if (_automationFeePerSec == 0) { return 0; }
        if (_expiryTime <= _currentTime) { return 0; }
        
        // Subtraction is safe here, as we already excluded expired tasks
        uint64 taskActiveTimeframe = _expiryTime - _currentTime;

        // If the task is a new task i.e. in Pending state, then it is charged always for
        // the input potential_fee_timeframe(which is epoch-interval),
        // For the new tasks which active-timeframe is less than epoch-interval
        // it would mean it is their first and only epoch and we charge the fee for entire epoch.
        // Note that although the new short tasks are charged for entire epoch, the refunding logic remains the same for
        // them as for the long tasks.
        // This way bad-actors will be discourged to submit small and short tasks with big occupancy by blocking other
        // good-actors register tasks.
        uint64 actualFeeTimeframe; 
        if(_state == AutomationStorage.TaskState.PENDING) {
            actualFeeTimeframe = _potentialFeeTimeframe;
        } else {
            actualFeeTimeframe = taskActiveTimeframe < _potentialFeeTimeframe ? taskActiveTimeframe : _potentialFeeTimeframe;
        }
        return registry.calculateAutomationFeeForInterval(
            actualFeeTimeframe,
            _maxGasAmount,
            _automationFeePerSec,
            _registryMaxGasCap
        );
    }

    function try_withdraw_task_automation_fee(
        uint64 _taskIndex,
        address _owner,
        uint64 _expiryTime,
        uint128 _lockedFeeForNextCycle,
        uint128 _fee,
        uint64 _currentCycleEndTime,
        uint128 _automationFeeCapForCycle,
        bytes32 _regHash
    ) internal {
        // Remove the automation task if the epoch fee cap is exceeded
        // It might happen that task has been expired by the time charging is being done.
        // This may be caused by the fact that bookkeeping transactions has been withheld due to epoch transition.
        if(_fee > _automationFeeCapForCycle) {
            // let task_meta = 
            refund_deposit_and_drop(
                _taskIndex,
                _owner,
                _lockedFeeForNextCycle, 
                _lockedFeeForNextCycle
            );

            emit TaskCancelledCapacitySurpassedV2(
                _taskIndex,
                _owner,
                _fee,
                _automationFeeCapForCycle,
                _regHash
            );
        }

        // TO_DO: check user balance
        uint256 userBalance = _owner.balance;
        if(userBalance < _fee) {
            // If the user does not have enough balance, remove the task, DON'T refund the locked deposit, but simply unlock it
            // and emit an event
            safe_unlock_locked_deposit(_taskIndex, _lockedFeeForNextCycle);
            registry.removeTask(_taskIndex);
            // TO_DO: add to removed

            emit TaskCancelledInsufficentBalanceV2(
                _taskIndex,
                _owner,
                _fee,
                userBalance,
                _regHash
            );
        } else if(_fee != 0) {
            // Charge the fee and emit a success event

            // TO_DO: withdraw funds from the user 

            // TO_DO: Merge to total task fees deducted from the users account
            emit TaskCycleFeeWithdraw(
                _taskIndex,
                _owner,
                _fee
            );
        
            // Calculate gas commitment for the next epoch only for valid active tasks
            if (_expiryTime > _currentCycleEndTime) {
                // TO_DO: calculaye gas commitment for next cycle
                // intermediate_state.gas_committed_for_next_cycle = intermediate_state.gas_committed_for_next_cycle+ task.max_gas_amount;
            }
        }
    }

    function drop_or_charge_task(
        uint64 _taskIndex,
        uint64 _currentTime,
        uint64 _currentCycleEndTime
        // AutomationStorage.IntermediateStateOfCycleChange storage _intermediateState
    ) internal {
        if(registry.ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }
        markTaskProcessed(_taskIndex);
         
        bool isUST = registry.isUST(_taskIndex);
        AutomationStorage.TaskMetadata memory task = registry.getTaskDetails(_taskIndex);
        
        // cancelled or expired
        if(task.state == AutomationStorage.TaskState.CANCELLED || _currentTime >= task.expiryTime) {
            if(isUST) {
                refund_deposit_and_drop(_taskIndex, task.owner, task.lockedFeeForNextCycle, task.lockedFeeForNextCycle);
            } else {
                drop_system_task(_taskIndex);
            }
        } else if(!isUST) {
            // active gst

            // Governance submitted tasks are not charged
            // _intermediateState.sysGasCommittedForNextCycle += task.maxGasAmount;
            registry.updateTaskState(_taskIndex, AutomationStorage.TaskState.ACTIVE);
        } else {
            // active ust
            uint128 registryMaxGasCap = registry.getRegistryMaxGasCap();

            uint128 fee = calculate_task_fee(
                task.state,
                task.expiryTime,
                task.maxGasAmount,
                cycleInfo.transitionState.newCycleDuration,
                _currentTime,
                cycleInfo.transitionState.automationFeePerSec,
                registryMaxGasCap
                );
            // If the task reached this phase that means it is valid active task for the new epoch.
            // During cleanup all expired tasks has been removed from the registry but the state of the tasks is not updated.
            // As here we need to distinguish new tasks from already existing active tasks,
            // as the fee calculation for them will be different based on their active duration in the epoch.
            // For more details see calculate_task_fee function.
            registry.updateTaskState(_taskIndex, AutomationStorage.TaskState.ACTIVE);

            // let task = AutomationTaskFeeMeta {
            //     task_index,
            //     owner: task_meta.owner,
            //     fee,
            //     expiry_time: task_meta.expiry_time,
            //     automation_fee_cap: task_meta.automation_fee_cap_for_epoch,
            //     max_gas_amount: task_meta.max_gas_amount,
            //     locked_deposit_fee: task_meta.locked_fee_for_next_epoch,
            // };
            try_withdraw_task_automation_fee(
                _taskIndex,
                task.owner,
                task.expiryTime,
                task.lockedFeeForNextCycle,
                fee,
                _currentCycleEndTime,
                task.automationFeeCapForCycle,
                task.txHash
            );
        }
    }

    /// Traverses all input task indexes and either drops or tries to charge automation fee if possible.
    function drop_or_charge_tasks(uint64[] memory taskIds) internal { 
        uint256 currentTime = block.timestamp;
        uint256 currentCycleEndTime = currentTime + cycleInfo.transitionState.newCycleDuration;

        // TO_DO: sort task indexes to charge automation fees in the tasks chronological order

        // Process each active task and calculate fee for the epoch for the tasks
        for (uint256 i = 0; i < taskIds.length; i++) {
            drop_or_charge_task(
                taskIds[i],
                uint64(currentTime),
                uint64(currentCycleEndTime)
            );
        }
    }

    function onCycleTransition(uint64 _cycleIndex, uint64[] memory _taskIndexes) internal {
        if(_taskIndexes.length == 0) { revert TaskIndexesCannotBeEmpty(); }
        if(cycleInfo.state != AutomationStorage.CycleState.FINISHED) { revert InvalidRegistryState(); }
        // TO_DO: check transition state
        if(cycleInfo.index + 1 != _cycleIndex) { revert InvalidInputCycleIndex(); }


        drop_or_charge_tasks(_taskIndexes);

    }
     
    /// Called by VM on `AutomationBookkeepingAction::Process` action emitted by native layer ahead of cycle transition
    function processTasks(uint64 _cycleIndex, uint64[] memory _taskIndexes) internal {
        // TO_DO: check to ensure it can only be called by VM

        if(cycleInfo.state == AutomationStorage.CycleState.FINISHED) {
            onCycleTransition(_cycleIndex, _taskIndexes);
        }

        if(cycleInfo.state != AutomationStorage.CycleState.SUSPENDED) { revert InvalidRegistryState(); }
        // onCycleSuspend(_cycleIndex, _taskIndexes);
    }


    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::: View Functions ::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    function getCycleState() public view returns (uint8) {
        return uint8(cycleInfo.state);
    }

    function getCycleInfo() public view returns (uint64, uint64) {
        return (cycleInfo.startTime, cycleInfo.durationSecs);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Upgradeability Functions :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
