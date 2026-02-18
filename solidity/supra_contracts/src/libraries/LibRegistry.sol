// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {LibUtils} from "./LibUtils.sol";
import {AppStorage, LibAppStorage, TaskMetadata} from "./LibAppStorage.sol";
import {IRegistryFacet} from "../interfaces/IRegistryFacet.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

library LibRegistry {
    using LibUtils for *;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @dev Constant for 10^8
    uint256 constant DECIMAL = 100_000_000;

    /// @dev Constants describing REFUND TYPE
    uint8 constant DEPOSIT_CYCLE_FEE = 0;
    uint8 constant CYCLE_FEE = 1;

    /// @dev Refund fraction
    uint8 constant REFUND_FRACTION = 2;

    /// @dev Defines divisor for refunds of deposit fees with penalty
    /// Factor of `2` suggests that `1/2` of the deposit will be refunded.
    uint8 constant REFUND_FACTOR = 2;

    /// @notice Address of the transaction hash precompile.
    address public constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000053555001;

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ERRORS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    error TransferFailed();
    error ErrorCycleFeeRefund();
    error RegistrationDisabled();
    error AutomationNotEnabled();
    error CycleTransitionInProgress();
    error TaskDoesNotExist();
    error ErrorDepositRefund();
    error RegisteredTaskInvalidType();
    error TaskIndexNotFound();
    error FailedToCallTxHashPrecompile();
    error TxnHashLengthShouldBe32(uint64);
    error InvalidMaxGasAmount();
    error GasCommittedExceedsMaxGasCap();
    error GasCommittedValueUnderflow();
    error InsufficientFeeCapForCycle();
    error InsufficientBalanceForRefund();
    error InvalidExpiryTime();
    error InvalidGasPriceCap();
    error InvalidTaskDuration();
    error TaskCapacityReached();
    error TaskExpiresBeforeNextCycle();

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Returns the total number of active tasks.
    function getTotalActiveTasks() internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.appStorage();
        return s.registryState.activeTaskIds.length();
    }

    /// @notice Returns all the active task indexes.
    function getAllActiveTaskIds() internal view returns (uint256[] memory) {
        AppStorage storage s = LibAppStorage.appStorage();
        return s.registryState.activeTaskIds.values();
    }

    /// @notice Returns the number of total tasks.
    function totalTasks() internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.appStorage();
        return s.registryState.taskIdList.length();
    }

    /// @notice Returns all the automation tasks available in the registry.
    function getTaskIdList() internal view returns (uint256[] memory) {
        AppStorage storage s = LibAppStorage.appStorage();
        return s.registryState.taskIdList.values();
    }

    /// @notice Checks whether cycle is in STARTED state.
    function isCycleStarted() internal view returns (bool) {
        AppStorage storage s = LibAppStorage.appStorage();
        return s.cycleState == LibUtils.CycleState.STARTED;
    }

    /// @notice Checks if a task exist.
    /// @param _taskIndex Task index to check if a task exists against it.
    function ifTaskExists(uint64 _taskIndex) internal view returns (bool) {
        AppStorage storage s = LibAppStorage.appStorage();
        return s.registryState.tasks[_taskIndex].owner != address(0) && s.registryState.taskIdList.contains(_taskIndex);
    }

    /// @notice Checks if a system task exist.
    /// @param _taskIndex Task index to check if a system task exists against it.
    function ifSysTaskExists(uint64 _taskIndex) internal view returns (bool) {
        AppStorage storage s = LibAppStorage.appStorage();
        return s.registryState.sysTaskIds.contains(_taskIndex);
    }

    /// @notice Returns the details of a task. Reverts if task doesn't exist.
    /// @param _taskIndex Task index to get details for.
    function getTask(uint64 _taskIndex) internal view returns (TaskMetadata storage task) {
        AppStorage storage s = LibAppStorage.appStorage();

        if (!ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }
        task = s.registryState.tasks[_taskIndex];
    }

    /// @notice Refunds the specified amount of deposit to the task owner and unlocks full deposit from the total automation fees deposited.
    /// @param _taskIndex Index of the task.
    /// @param _taskOwner Owner of the task.
    /// @param _refundableDeposit Refundable amount of deposit.
    /// @param _lockedDeposit Total locked deposit.
    function safeDepositRefund(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) internal returns (bool) {
        // Ensures that amount to unlock is not more than the total automation fees deposited.
        bool result = safeUnlockLockedDeposit(_taskIndex, _lockedDeposit);
        if (!result) {
            return result;
        }

        result = safeRefund(_taskIndex, _taskOwner, _refundableDeposit, DEPOSIT_CYCLE_FEE);

        if (result) { emit IRegistryFacet.TaskDepositFeeRefund(_taskIndex, _taskOwner, _refundableDeposit); }
        return result;
    }
    
    /// @notice Refunds the deposit fee and any autoamtion fees of the task.
    function refundTaskFees(
        uint64 _currentTime,
        uint64 _refundDuration, 
        uint128 _automationFeePerSec,
        TaskMetadata memory _task
    ) internal {
        AppStorage storage s = LibAppStorage.appStorage();

        // Do not attempt fee refund if remaining duration is 0
        if (_task.taskState != LibUtils.TaskState.PENDING && _refundDuration != 0) {
            uint128 _refundFee = calculateTaskFee(
                _task.taskState,
                _task.expiryTime,
                _task.maxGasAmount,
                _refundDuration,
                _currentTime,
                _automationFeePerSec
            );
            ( , uint256 remainingCycleLockedFees) = safeFeeRefund(
                    _task.taskIndex,
                    _task.owner,
                    s.registryState.cycleLockedFees,
                    uint64(_refundFee)
                );
            s.registryState.cycleLockedFees = remainingCycleLockedFees;
        }

        safeDepositRefund(
            _task.taskIndex,
            _task.owner,
            _task.depositFee,
            _task.depositFee
        );
    }

    /// @notice Calculates automation task fees for a single task at the time of new cycle.
    /// This is supposed to be called only after removing expired task and must not be called for expired task.
    function calculateAutomationFeeForInterval(
        uint64 _duration,
        uint128 _taskOccupancy,
        uint128 _automationFeePerSec,
        uint128 _registryMaxGasCap
    ) private pure returns (uint128) {
        uint256 taskOccupancyRatioByDuration = (uint256(_duration) * uint256(_taskOccupancy) * DECIMAL) / uint256(_registryMaxGasCap);

        uint256 automationFeeForInterval = _automationFeePerSec * taskOccupancyRatioByDuration;

        return uint128(automationFeeForInterval / DECIMAL);
    }

    /// @notice Calculates automation task fees for a single task at the time of new cycle.
    /// This is supposed to be called only after removing expired task and must not be called for expired task.    
    /// @param _state State of the task.
    /// @param _expiryTime Task expiry time.
    /// @param _maxGasAmount Task's max gas amount
    /// @param _potentialFeeTimeframe Potential time frame to calculate task fees for.
    /// @param _currentTime Current time
    /// @param _automationFeePerSec Automation fee per sec
    /// @return Calculated task fee for the interval the task will be active.
    function calculateTaskFee(
        LibUtils.TaskState _state,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _potentialFeeTimeframe,
        uint64 _currentTime,
        uint128 _automationFeePerSec
    ) internal view returns (uint128) {
        if (_automationFeePerSec == 0) { return 0; }
        if (_expiryTime <= _currentTime) { return 0; }
        
        uint64 taskActiveTimeframe = _expiryTime - _currentTime;

        // If the task is a new task i.e. in Pending state, then it is charged always for
        // the input _potentialFeeTimeframe(which is cycle-interval),
        // For the new tasks which active-timeframe is less than cycle-interval
        // it would mean it is their first and only cycle and we charge the fee for entire cycle.
        // Note that although the new short tasks are charged for entire cycle, the refunding logic remains the same for
        // them as for the long tasks.
        // This way bad-actors will be discourged to submit small and short tasks with big occupancy by blocking other
        // good-actors register tasks.
        uint64 actualFeeTimeframe; 
        if (_state == LibUtils.TaskState.PENDING) {
            actualFeeTimeframe = _potentialFeeTimeframe;
        } else {
            actualFeeTimeframe = taskActiveTimeframe < _potentialFeeTimeframe ? taskActiveTimeframe : _potentialFeeTimeframe;
        }

        AppStorage storage s = LibAppStorage.appStorage();
        return calculateAutomationFeeForInterval(
            actualFeeTimeframe,
            _maxGasAmount,
            _automationFeePerSec,
            s.activeConfig.registryMaxGasCap
        );
    }

    /// @notice Unlocks the locked fee paid by the task for cycle.
    /// Error event is emitted if the cycle locked fee amount is inconsistent with the requested unlock amount.
    /// @param _cycleLockedFees Locked cycle fees
    /// @param _refundableFee Refundable fees
    /// @param _taskIndex Index of the task
    /// @return Bool if _refundableFee can be unlocked safely.
    /// @return Updated _cycleLockedFees after unlocking _refundableFee.
    function safeUnlockLockedCycleFee(
        uint256 _cycleLockedFees,
        uint64 _refundableFee,
        uint64 _taskIndex
    ) private returns (bool, uint256) {
        // This check makes sure that more than locked amount of the fees will be not be refunded.
        // Any attempt means internal bug.
        bool hasLockedFee = _cycleLockedFees >= _refundableFee;
        if (hasLockedFee) {
            // Unlock the refunded amount
            _cycleLockedFees = _cycleLockedFees - _refundableFee;
        } else {
            emit IRegistryFacet.ErrorUnlockTaskCycleFee(_taskIndex, _cycleLockedFees, _refundableFee);
        }
        return (hasLockedFee, _cycleLockedFees);
    }

    /// @notice Helper function to transfer refunds.
    /// @param _erc20Supra Address of the ERC20Supra token.
    /// @param _to Recipeint of the refund
    /// @param _amount Amount to refund
    /// @return Bool representing if refund was successful.
    function _refund(address _erc20Supra, address _to, uint128 _amount) private returns (bool) {
        bool sent = IERC20(_erc20Supra).transfer(_to, _amount);
        if (!sent) { revert TransferFailed(); }

        return sent;
    }

    /// @notice Refunds the specified amount to the task owner.
    /// @dev Error event is emitted if the registry contract does not have sufficient balance.
    /// @param _taskIndex Index of the task.
    /// @param _taskOwner Owner of the task.
    /// @param _refundableAmount Amount to refund.
    /// @param _refundType Type of refund.
    /// @return Bool representing if refund was successful.
    function safeRefund(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableAmount,
        uint8 _refundType
    ) private returns (bool) {
        AppStorage storage s = LibAppStorage.appStorage();

        address erc20Supra = s.erc20Supra;
        uint256 balance = IERC20(erc20Supra).balanceOf(address(this));
        if (balance < _refundableAmount) {
            emit IRegistryFacet.ErrorInsufficientBalanceToRefund(_taskIndex, _taskOwner, _refundType, _refundableAmount);
            return false;
        } else {
            return _refund(erc20Supra, _taskOwner, _refundableAmount);
        }
    }

    /// @notice Refunds fee paid by the task for the cycle to the task owner.
    /// Note that here we do not unlock the fee, as on cycle change locked cycle-fees for the ended cycle are
    /// automatically unlocked.
    function safeFeeRefund(
        uint64 _taskIndex,
        address _taskOwner,
        uint256 _cycleLockedFees,
        uint64 _refundableFee
    ) private returns (bool, uint256) {
        bool result;
        uint256 remainingLockedFees;
        
        (result, remainingLockedFees) = safeUnlockLockedCycleFee(_cycleLockedFees, _refundableFee, _taskIndex);
        if (!result) { return (result, remainingLockedFees); } 
        
        result = safeRefund( _taskIndex, _taskOwner, _refundableFee, CYCLE_FEE);
        if (result) { emit IRegistryFacet.TaskFeeRefund(_taskIndex, _taskOwner, _refundableFee); }
        return (result, remainingLockedFees);   
    }

    /// @notice Internally calls _refund, reverts if caller is not AutomationRegistry.
    function refund(address _to, uint128 _amount) internal {
        AppStorage storage s = LibAppStorage.appStorage();
        
        address erc20Supra = s.erc20Supra;
        uint256 balance = IERC20(erc20Supra).balanceOf(address(this));
        if (balance < _amount) { revert InsufficientBalanceForRefund(); }
        _refund(erc20Supra, _to, _amount);
    }

    /// @notice Unlocks the deposit paid by the task from the total automation fees deposited.
    /// @dev Error event is emitted if the total automation fees deposited is less than the requested unlock amount.
    /// @param _taskIndex Index of the task. 
    /// @param _lockedDeposit Locked deposit amount to be unlocked.
    /// @return Bool if _lockedDeposit can be unlocked safely.
    function safeUnlockLockedDeposit(
        uint64 _taskIndex,
        uint128 _lockedDeposit
    ) internal returns (bool) {
        AppStorage storage s = LibAppStorage.appStorage();

        uint256 totalDeposited = s.registryState.totalDepositedAutomationFees;
        
        if (totalDeposited >= _lockedDeposit) {
            s.registryState.totalDepositedAutomationFees = totalDeposited - _lockedDeposit;
            return true;
        }

        emit IRegistryFacet.ErrorUnlockTaskDepositFee(_taskIndex, totalDeposited, _lockedDeposit);
        return false;
    }

    /// @notice Calculates the automation fee multiplier for current cycle. 
    function calculateAutomationFeeMultiplierForCurrentCycle() internal view returns (uint128) {
        AppStorage storage s = LibAppStorage.appStorage();

        // Compute the automation fee multiplier for this cycle
        return calculateAutomationFeeMultiplierForCycle(
            s.registryState.gasCommittedForThisCycle,
            s.activeConfig.registryMaxGasCap,
            s.activeConfig.automationBaseFeeWeiPerSec
        );
    }

    /// @notice Calculates the automation fee multiplier for cycle.
    /// @param _totalCommittedGas Total committed gas.
    /// @param _registryMaxGasCap Registry max gas cap.
    /// @param _automationBaseFeeWeiPerSec Automation base fee in wei per sec.
    function calculateAutomationFeeMultiplierForCycle(
        uint128 _totalCommittedGas,
        uint128 _registryMaxGasCap,
        uint128 _automationBaseFeeWeiPerSec
    ) private view returns (uint128) {
        uint128 congesionFee = calculateAutomationCongestionFee(_totalCommittedGas, _registryMaxGasCap);
        return (congesionFee + _automationBaseFeeWeiPerSec);
    }

    /// @notice Function to calculate the automation congestion fee.
    /// @param _totalCommittedGas Total committed gas.
    /// @param _registryMaxGasCap Registry max gas cap.
    /// @return Returns the automation congestion fee.
    function calculateAutomationCongestionFee(
        uint128 _totalCommittedGas,
        uint128 _registryMaxGasCap
    ) internal view returns (uint128) {
        AppStorage storage s = LibAppStorage.appStorage();
        if (s.activeConfig.congestionThresholdPercentage == 100 || s.activeConfig.congestionBaseFeeWeiPerSec == 0) { return 0; }
    
        // thresholdUsage = (totalCommittedGas / maxGasCap) * 100
        uint256 thresholdUsageScaled = (uint256(_totalCommittedGas) * DECIMAL * 100) / uint256(_registryMaxGasCap);

        uint256 thresholdPercentageScaled = uint256(s.activeConfig.congestionThresholdPercentage) * DECIMAL;

        // If usage is below threshold → no congestion fee
        if (thresholdUsageScaled <= thresholdPercentageScaled) {
            return 0;
        } else {
            // Calculate how much usage exceeds threshold
            uint256 surplusScaled = (thresholdUsageScaled - thresholdPercentageScaled) / 100;


            // Ensure threshold + threshold surplus does not exceed 1 (1 in scaled terms)
            uint256 thresholdScaledAsFraction = thresholdPercentageScaled / 100;    // DECIMAL-scaled fraction
            uint256 surplusClipped = thresholdScaledAsFraction + surplusScaled > DECIMAL ? DECIMAL - thresholdScaledAsFraction : surplusScaled;

            uint256 baseScaled = DECIMAL + surplusClipped;  // (1 + base)
            uint256 resultScaled = DECIMAL;
            for (uint8 i = 0; i < s.activeConfig.congestionExponent; i++) {
                resultScaled = (resultScaled * baseScaled) / DECIMAL;
            }
            uint256 exponentResult = resultScaled - DECIMAL;    // subtract 1


            // Multiply base fee (wei/sec) with exponentResult and downscale by DECIMAL
            uint256 acf = (uint256(s.activeConfig.congestionBaseFeeWeiPerSec) * exponentResult) / DECIMAL;

            return uint128(acf);
        }
    }

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

    /// @notice Calculates automation fee per second for the specified task occupancy
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and current registry
    /// maximum allowed occupancy.
    function calculateAutomationFeeMultiplierForCommittedOccupancy(
        uint128 _totalCommittedMaxGas
    ) internal view returns (uint128) {
        AppStorage storage s = LibAppStorage.appStorage();

        // Compute the automation fee multiplier for cycle        
        return calculateAutomationFeeMultiplierForCycle(
            _totalCommittedMaxGas,
            s.activeConfig.registryMaxGasCap,
            s.activeConfig.automationBaseFeeWeiPerSec
        );
    }

    /// @notice Helper function to charge fees from the user.
    function chargeFees(address _from, uint256 _amount) internal {
        AppStorage storage s = LibAppStorage.appStorage();
        
        bool sent = IERC20(s.erc20Supra).transferFrom(_from, address(this), _amount);
        if (!sent) { revert TransferFailed(); }
    }

    /// @notice Refunds the deposit fee of the task and removes from the registry.
    /// @param _taskIndex Index of the task.
    /// @param _taskOwner Owner of the task.
    /// @param _refundableDeposit Refundable amount of deposit.
    /// @param _lockedDeposit Total locked deposit.
    function refundDepositAndDrop(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) internal {
        AppStorage storage s = LibAppStorage.appStorage();

        // Check if task is UST
        if (s.registryState.tasks[_taskIndex].taskType == LibUtils.TaskType.GST) { revert RegisteredTaskInvalidType(); }

        // Remove task from the registry state
        removeTask(_taskIndex, _taskOwner,false);

        // Refund
        safeDepositRefund(
            _taskIndex,
            _taskOwner,
            _refundableDeposit,
            _lockedDeposit
        );
    }

    /// @notice Helper function that performs validation and updates state for a valid task.
    function updateStateForValidRegistration(
        uint256 _totalTasks, 
        uint64 _regTime,
        uint64 _expiryTime,
        LibUtils.TaskType _taskType,
        bytes memory _payloadTx, 
        uint128 _maxGasAmount, 
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle
    ) internal {
        AppStorage storage s = LibAppStorage.appStorage();

        // Check if automation and registration is enabled
        if (!s.automationEnabled) { revert AutomationNotEnabled(); }
        if (!s.registrationEnabled) { revert RegistrationDisabled(); }

        if (!isCycleStarted()) { revert CycleTransitionInProgress(); }
        
        bool isUST = _taskType == LibUtils.TaskType.UST;
   
        uint64 taskDurationCap;
        uint128 gasCommittedForNextCycle;
        uint128 nextCycleRegistryMaxGasCap;
        if (isUST) {
            if (_totalTasks >= s.activeConfig.taskCapacity) { revert TaskCapacityReached(); }
            if (_gasPriceCap == 0) { revert InvalidGasPriceCap(); }

            gasCommittedForNextCycle = s.registryState.gasCommittedForNextCycle;
            uint128 estimatedAutomationFeeForCycle = estimateAutomationFeeWithCommittedOccupancyInternal(_maxGasAmount, gasCommittedForNextCycle);
            if (_automationFeeCapForCycle < estimatedAutomationFeeForCycle) { revert InsufficientFeeCapForCycle(); }

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

        if (isUST) {
            s.registryState.gasCommittedForNextCycle = gasCommitted;
        } else {
            s.registryState.sysGasCommittedForNextCycle = gasCommitted;
        } 
    }

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
        ( , address payloadTarget, , ) = abi.decode(_payloadTx, (uint128, address, bytes, LibUtils.AccessListEntry[]));
        payloadTarget.validateContractAddress();
        
        if (_maxGasAmount == 0) { revert InvalidMaxGasAmount(); }
    }

    /// @notice Estimates automation fee the next cycle for specified task occupancy for the configured cycle interval
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and registry
    /// maximum allowed occupancy for the next cycle.
    /// Note it is expected that committed_occupancy does not include current task's occupancy.
    function estimateAutomationFeeWithCommittedOccupancyInternal(
        uint128 _taskOccupancy,
        uint128 _committedOccupancy
    ) internal view returns (uint128) {
        AppStorage storage s = LibAppStorage.appStorage();

        uint128 totalCommittedGas = _taskOccupancy + _committedOccupancy;
         
        uint128 automationFeePerSec = calculateAutomationFeeMultiplierForCycle(
            totalCommittedGas, 
            s.registryState.nextCycleRegistryMaxGasCap,
            s.activeConfig.automationBaseFeeWeiPerSec
        );

        if (automationFeePerSec == 0) return 0;
        return calculateAutomationFeeForInterval(s.durationSecs, _taskOccupancy, automationFeePerSec, s.registryState.nextCycleRegistryMaxGasCap);
    }

    function updateGasCommittedForNextCycle(LibUtils.TaskType _taskType, uint128 _maxGasAmount) external {
        AppStorage storage s = LibAppStorage.appStorage();

        bool isUST = _taskType == LibUtils.TaskType.UST;

        uint128 gasCommittedForNextCycle = isUST ? s.registryState.gasCommittedForNextCycle : s.registryState.sysGasCommittedForNextCycle;
        if (gasCommittedForNextCycle < _maxGasAmount) { revert GasCommittedValueUnderflow(); }
       
        // Adjust the gas committed for the next cycle by subtracting the gas amount of the cancelled/stopped task
        if (isUST) {
            s.registryState.gasCommittedForNextCycle = gasCommittedForNextCycle - _maxGasAmount;
        } else {
            s.registryState.sysGasCommittedForNextCycle = gasCommittedForNextCycle - _maxGasAmount;
        }
    }

    /// @notice Helper function to unlock locked deposit and cycle fees when stopTasks is called.
    function unlockDepositAndCycleFee(
        uint64 _taskIndex,
        LibUtils.TaskState _taskState,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _residualInterval,
        uint64 _currentTime,
        uint128 _depositFee
    )  internal returns (uint128, uint128) {
        AppStorage storage s = LibAppStorage.appStorage();

        uint128 cycleFeeRefund;
        uint128 depositRefund;

        if (_taskState != LibUtils.TaskState.PENDING) {
            // Compute the automation fee multiplier for cycle
            uint128 automationFeePerSec = calculateAutomationFeeMultiplierForCycle(
                s.registryState.gasCommittedForThisCycle, 
                s.activeConfig.registryMaxGasCap,
                s.activeConfig.automationBaseFeeWeiPerSec
            );

            uint128 taskFee = calculateTaskFee(
                _taskState,
                _expiryTime,
                _maxGasAmount,
                _residualInterval,
                _currentTime,
                automationFeePerSec
            );

            // Refund full deposit and the half of the remaining run-time fee when task is active or cancelled stage
            cycleFeeRefund = taskFee / REFUND_FRACTION; 
            depositRefund = _depositFee;
        } else {
            cycleFeeRefund = 0;
            depositRefund = _depositFee / REFUND_FRACTION;
        }

        bool result = safeUnlockLockedDeposit(_taskIndex, _depositFee);
        if (!result) { revert ErrorDepositRefund(); }

        (bool hasLockedFee, uint256 remainingCycleLockedFees ) = safeUnlockLockedCycleFee(s.registryState.cycleLockedFees, uint64(cycleFeeRefund), _taskIndex);
        if (!hasLockedFee) { revert ErrorCycleFeeRefund(); }

        s.registryState.cycleLockedFees = remainingCycleLockedFees;

        return (cycleFeeRefund, depositRefund);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: HELPER FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Function to remove a task from the registry.
    /// @param _taskIndex Index of the task to remove.
    /// @param _owner Address of the task owner.  
    /// @param _removeFromSysReg Wheather to remove from system task registry.
    function removeTask(uint64 _taskIndex, address _owner, bool _removeFromSysReg) internal {
        AppStorage storage s = LibAppStorage.appStorage();

        if (_removeFromSysReg) {
            require(s.registryState.sysTaskIds.remove(_taskIndex), TaskIndexNotFound());
        }

        delete s.registryState.tasks[_taskIndex];
        require(s.registryState.taskIdList.remove(_taskIndex), TaskIndexNotFound());
        require(s.registryState.userTasks[_owner].remove(_taskIndex), TaskIndexNotFound());
    }

    /// @notice Read tx hash via precompile. Reverts if precompile missing/fails.
    function readTxHash() internal view returns (bytes32) {
        (bool ok, bytes memory out) = TX_HASH_PRECOMPILE.staticcall("");
        require(ok, FailedToCallTxHashPrecompile());
        require(out.length == 32, TxnHashLengthShouldBe32(uint64(out.length)));
        return abi.decode(out, (bytes32));
    }
}
