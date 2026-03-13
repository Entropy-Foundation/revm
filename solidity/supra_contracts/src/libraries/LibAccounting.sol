// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AppStorage, Config, LibAppStorage, RegistryState, TaskMetadata} from "./LibAppStorage.sol";
import {LibCommon} from "./LibCommon.sol";
import {IRegistryFacet} from "../interfaces/IRegistryFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library LibAccounting {

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

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ERRORS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    error ErrorCycleFeeRefund();
    error ErrorDepositRefund();
    error InsufficientBalanceForRefund();
    error InvalidCycleRefundFee();
    error RegisteredTaskInvalidType();
    error TransferFailed();

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: PRIVATE FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

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
    ) private view returns (uint128) {
        Config storage activeConfig = LibAppStorage.activeConfig();

        uint8 congestionThresholdPercentage = activeConfig.congestionThresholdPercentage;
        uint8 congestionExponent = activeConfig.congestionExponent;
        uint128 congestionBaseFeeWeiPerSec = activeConfig.congestionBaseFeeWeiPerSec;

        if (congestionThresholdPercentage == 100 || congestionBaseFeeWeiPerSec == 0) { return 0; }
    
        // thresholdUsage = (totalCommittedGas / maxGasCap) * 100
        uint256 thresholdUsageScaled = (uint256(_totalCommittedGas) * DECIMAL * 100) / uint256(_registryMaxGasCap);

        uint256 thresholdPercentageScaled = uint256(congestionThresholdPercentage) * DECIMAL;

        // If usage is below threshold → no congestion fee
        if (thresholdUsageScaled <= thresholdPercentageScaled) {
            return 0;
        }

        // Calculate how much usage exceeds threshold
        uint256 surplusScaled = (thresholdUsageScaled - thresholdPercentageScaled) / 100;

        // Ensure threshold + threshold surplus does not exceed 1 (1 in scaled terms)
        uint256 thresholdScaledAsFraction = thresholdPercentageScaled / 100;    // DECIMAL-scaled fraction
        uint256 surplusClipped = thresholdScaledAsFraction + surplusScaled > DECIMAL ? DECIMAL - thresholdScaledAsFraction : surplusScaled;
        
        uint256 exponentResult = calculateExponentiation(
            surplusClipped,
            congestionExponent
        );

        // Multiply base fee (wei/sec) with exponentResult and downscale by DECIMAL
        uint256 acf = (uint256(congestionBaseFeeWeiPerSec) * exponentResult) / DECIMAL;

        return uint128(acf);
    }

    /// @notice Computes exponentiation using fixed-point arithmetic.
    function calculateExponentiation(
        uint256 _base,
        uint8 _exponent
    ) private pure returns (uint256) {
        uint256 baseScaled = DECIMAL + _base;   // (1 + base)
        uint256 resultScaled = DECIMAL;

        while (_exponent > 0) {
            if ((_exponent & 1) != 0) {
               resultScaled = (resultScaled * baseScaled) / DECIMAL;
            }
         
            _exponent >>= 1;
            if (_exponent > 0) {
                baseScaled = (baseScaled * baseScaled) / DECIMAL;
            }
        }      
    
        return resultScaled - DECIMAL;      // subtract 1
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

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: INTERNAL FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Refunds the deposit fee and any autoamtion fees of the task.
    function refundTaskFees(
        uint64 _currentTime,
        uint64 _refundDuration, 
        uint128 _automationFeePerSec,
        TaskMetadata memory _task
    ) internal {
        RegistryState storage registryState = LibAppStorage.registryState();

        // Do not attempt fee refund if remaining duration is 0
        if (_task.taskState != LibCommon.TaskState.PENDING && _refundDuration != 0) {
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
                    registryState.cycleLockedFees,
                    uint64(_refundFee)
                );
            registryState.cycleLockedFees = remainingCycleLockedFees;
        }

        safeDepositRefund(
            _task.taskIndex,
            _task.owner,
            _task.depositFee,
            _task.depositFee
        );
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
        // Check if task is UST
        if (LibAppStorage.registryState().tasks[_taskIndex].taskType == LibCommon.TaskType.GST) { revert RegisteredTaskInvalidType(); }

        // Remove task from the registry state
        LibCommon.removeTask(_taskIndex, _taskOwner,false);

        // Refund
        safeDepositRefund(
            _taskIndex,
            _taskOwner,
            _refundableDeposit,
            _lockedDeposit
        );
    }

    /// @notice Internally calls _refund, reverts if caller is not AutomationRegistry.
    function refund(address _to, uint128 _amount) internal {
        AppStorage storage s = LibAppStorage.appStorage();
        
        address erc20Supra = s.erc20Supra;
        uint256 balance = IERC20(erc20Supra).balanceOf(address(this));
        if (balance < _amount) { revert InsufficientBalanceForRefund(); }
        _refund(erc20Supra, _to, _amount);
    }

    /// @notice Calculates the automation fee multiplier for current cycle. 
    function calculateAutomationFeeMultiplierForCurrentCycle() internal view returns (uint128) {
        Config storage activeConfig = LibAppStorage.activeConfig();

        // Compute the automation fee multiplier for this cycle
        return calculateAutomationFeeMultiplierForCycle(
            LibAppStorage.registryState().gasCommittedForThisCycle,
            activeConfig.registryMaxGasCap,
            activeConfig.automationBaseFeeWeiPerSec
        );
    }

    /// @notice Calculates automation fee per second for the specified task occupancy
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and current registry
    /// maximum allowed occupancy.
    function calculateAutomationFeeMultiplierForCommittedOccupancy(
        uint128 _totalCommittedMaxGas
    ) internal view returns (uint128) {
        Config storage activeConfig = LibAppStorage.activeConfig();

        // Compute the automation fee multiplier for cycle        
        return calculateAutomationFeeMultiplierForCycle(
            _totalCommittedMaxGas,
            activeConfig.registryMaxGasCap,
            activeConfig.automationBaseFeeWeiPerSec
        );
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
        RegistryState storage registryState = LibAppStorage.registryState();

        uint128 totalCommittedGas = _taskOccupancy + _committedOccupancy;
         
        uint128 automationFeePerSec = calculateAutomationFeeMultiplierForCycle(
            totalCommittedGas, 
            registryState.nextCycleRegistryMaxGasCap,
            LibAppStorage.activeConfig().automationBaseFeeWeiPerSec
        );

        if (automationFeePerSec == 0) return 0;
        return calculateAutomationFeeForInterval(s.durationSecs, _taskOccupancy, automationFeePerSec, registryState.nextCycleRegistryMaxGasCap);
    }

    /// @notice Helper function to unlock locked deposit and cycle fees when stopTasks is called.
    function unlockDepositAndCycleFee(
        uint64 _taskIndex,
        LibCommon.TaskState _taskState,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _residualInterval,
        uint64 _currentTime,
        uint128 _depositFee
    )  internal returns (uint128, uint128) {
        AppStorage storage s = LibAppStorage.appStorage();
        RegistryState storage registryState = LibAppStorage.registryState();

        uint128 cycleLockedFeeForTask;
        uint128 cycleFeeRefund;
        uint128 depositRefund;

        if (_taskState != LibCommon.TaskState.PENDING) {
            // Compute the automation fee multiplier for cycle
            Config storage activeConfig = LibAppStorage.activeConfig();
            uint128 automationFeePerSec = calculateAutomationFeeMultiplierForCycle(
                registryState.gasCommittedForThisCycle, 
                activeConfig.registryMaxGasCap,
                activeConfig.automationBaseFeeWeiPerSec
            );

            uint128 taskFeeForFullCycle = calculateAutomationFeeForInterval(s.durationSecs, _maxGasAmount, automationFeePerSec, activeConfig.registryMaxGasCap);
            uint128 taskFeeForResidualTime = calculateTaskFee(
                _taskState,
                _expiryTime,
                _maxGasAmount,
                _residualInterval,
                _currentTime,
                automationFeePerSec
            );

            // Refund full deposit and the half of the remaining run-time fee when task is active or cancelled stage
            cycleLockedFeeForTask = taskFeeForFullCycle;
            cycleFeeRefund = taskFeeForResidualTime / REFUND_FRACTION; 
            depositRefund = _depositFee;
        } else {
            cycleLockedFeeForTask = 0;
            cycleFeeRefund = 0;
            depositRefund = _depositFee / REFUND_FRACTION;
        }

        bool result = safeUnlockLockedDeposit(_taskIndex, _depositFee);
        if (!result) { revert ErrorDepositRefund(); }

        if (cycleLockedFeeForTask < cycleFeeRefund) { revert InvalidCycleRefundFee(); }

        (bool hasLockedFee, uint256 remainingCycleLockedFees ) = safeUnlockLockedCycleFee(registryState.cycleLockedFees, uint64(cycleLockedFeeForTask), _taskIndex);
        if (!hasLockedFee) { revert ErrorCycleFeeRefund(); }

        registryState.cycleLockedFees = remainingCycleLockedFees;

        return (cycleFeeRefund, depositRefund);
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
        RegistryState storage registryState = LibAppStorage.registryState();

        uint256 totalDeposited = registryState.totalDepositedAutomationFees;
        
        if (totalDeposited >= _lockedDeposit) {
            registryState.totalDepositedAutomationFees = totalDeposited - _lockedDeposit;
            return true;
        }

        emit IRegistryFacet.ErrorUnlockTaskDepositFee(_taskIndex, totalDeposited, _lockedDeposit);
        return false;
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
        LibCommon.TaskState _state,
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
        if (_state == LibCommon.TaskState.PENDING) {
            actualFeeTimeframe = _potentialFeeTimeframe;
        } else {
            actualFeeTimeframe = taskActiveTimeframe < _potentialFeeTimeframe ? taskActiveTimeframe : _potentialFeeTimeframe;
        }

        return calculateAutomationFeeForInterval(
            actualFeeTimeframe,
            _maxGasAmount,
            _automationFeePerSec,
            LibAppStorage.activeConfig().registryMaxGasCap
        );
    }
}