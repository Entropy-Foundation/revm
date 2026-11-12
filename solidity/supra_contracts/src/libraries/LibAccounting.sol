// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AppStorage, Config, LibAppStorage, RegistryState, TaskMetadataLW} from "./LibAppStorage.sol";
import {LibCommon} from "./LibCommon.sol";
import {ICoreFacet} from "../interfaces/ICoreFacet.sol";
import {IRegistryFacet} from "../interfaces/IRegistryFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library LibAccounting {
    using LibAccounting for CycleOccupancy;

    /// @dev Constant for 10^8
    uint256 constant DECIMAL = 100_000_000;

    /// @dev 100% in the unit of the congestion percentages below: percent scaled by DECIMAL.
    uint256 constant HUNDRED_PERCENT_SCALED = uint256(LibCommon.HUNDRED_PERCENT) * DECIMAL;

    /// @dev Constants describing REFUND TYPE
    uint8 constant DEPOSIT_CYCLE_FEE = 0;
    uint8 constant CYCLE_FEE = 1;

    /// @dev Defines divisor for refunds of deposit fees with penalty
    /// Factor of `2` suggests that `1/2` of the deposit will be refunded.
    uint8 constant REFUND_FACTOR = 2;

    /// @dev Divisor for refunds without penalty: the whole amount is refunded. Applied to a task
    /// removed because the EVM gas config no longer admits it (#4087).
    uint8 constant FULL_REFUND_FACTOR = 1;

    /// @notice The user-task occupancy of one cycle, the limits it is measured against and the fee
    /// parameters it is priced with: every input of a UST fee for that cycle other than the task
    /// itself and the time interval (Entropy-Foundation/smr-moonshot#4921).
    /// @dev The registry has two limited resources, the gas cap and the task capacity, and an
    /// occupancy carries both. {calculateAutomationCongestionFee} prices the per-second rate on
    /// the larger of the two shares, and {billedGas} bills a task for part of a slot's worth of
    /// gas once the task share passes the congestion threshold.
    /// A cycle's fees are charged at the transition into it and recomputed when a task is stopped
    /// or removed during it, to unlock the charged fee and refund its unused part. Both use the
    /// same occupancy, read from the per-cycle snapshots (`gasCommittedForThisCycle`,
    /// `tasksCommittedForThisCycle`, or their transition counterparts) and never from a count that
    /// changes during the cycle, so the recomputed fee equals the charged one.
    struct CycleOccupancy {
        /// Gas committed by USTs to the cycle.
        uint128 committedGas;
        /// Number of USTs committed to the cycle, one per task whatever its gas.
        uint32 committedTasks;
        /// Registry max gas cap of the cycle.
        uint128 registryMaxGasCap;
        /// UST capacity of the cycle.
        uint16 taskCapacity;
        /// Config.congestionThresholdPercentage: the share, of gas or of tasks, above which the
        /// cycle is congested. 100 disables congestion pricing.
        uint8 congestionThresholdPercentage;
        /// Config.congestionExponent.
        uint8 congestionExponent;
        /// Config.automationBaseFeeWeiPerSec.
        uint128 automationBaseFeeWeiPerSec;
        /// Config.congestionBaseFeeWeiPerSec. Zero disables congestion pricing.
        uint128 congestionBaseFeeWeiPerSec;
    }

    /// @notice A cycle's occupancy with the fee per second it yields, computed once by a call that
    /// prices several tasks of the same cycle (`stopTasks`, `removeTasks`, a suspension batch).
    struct CyclePricing {
        CycleOccupancy occupancy;
        uint128 automationFeePerSec;
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: PRIVATE FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Refunds fee paid by the task for the cycle to the task owner.
    /// Note that here we do not unlock the fee, as on cycle change locked cycle-fees for the ended cycle are
    /// automatically unlocked.
    function safeFeeRefund(
        uint64 _taskIndex,
        address _taskOwner,
        uint256 _cycleLockedFees,
        uint128 _refundableFee
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
    /// @param _erc20Supra Address of the WrappedSupra token.
    /// @param _to Recipeint of the refund
    /// @param _amount Amount to refund
    /// @return Bool representing if refund was successful.
    function _refund(address _erc20Supra, address _to, uint128 _amount) private returns (bool) {
        bool sent = IERC20(_erc20Supra).transfer(_to, _amount);
        if (!sent) { revert IRegistryFacet.TransferFailed(); }

        return sent;
    }

    /// @notice Calculates the automation fee per second, base fee plus congestion fee, for a cycle
    /// with occupancy `_occupancy`.
    /// @param _occupancy Occupancy and fee parameters of the cycle the fee is for.
    function calculateAutomationFeeMultiplierForCycle(
        CycleOccupancy memory _occupancy
    ) private pure returns (uint128) {
        uint128 congesionFee = calculateAutomationCongestionFee(_occupancy);
        return (congesionFee + _occupancy.automationBaseFeeWeiPerSec);
    }

    /// @notice Calculates the automation congestion fee per second for a cycle with occupancy
    /// `_occupancy`.
    /// @dev The usage priced is the larger of the gas share (`committedGas / registryMaxGasCap`)
    /// and the task share (`committedTasks / taskCapacity`), so a cycle whose task capacity is
    /// taken is congested in the same way as one whose gas cap is (#4921). Above the threshold
    /// the fee grows with the surplus as `congestionBaseFee * ((1 + surplus)^exponent - 1)`, with
    /// the usage counted as at most 100%.
    /// @param _occupancy Occupancy of the cycle the fee is for.
    /// @return Returns the automation congestion fee.
    function calculateAutomationCongestionFee(
        CycleOccupancy memory _occupancy
    ) private pure returns (uint128) {
        if (!_occupancy.isCongestionPriced()) { return 0; }

        // Usage above the threshold, in percent scaled by DECIMAL; zero when not congested.
        uint256 surplus = _occupancy.congestionSurplus();
        if (surplus == 0) { return 0; }

        // The surplus, in percent scaled by DECIMAL, divided by 100% is a fraction scaled by
        // DECIMAL: the base of (1 + surplus)^exponent.
        uint256 exponentResult =
            calculateExponentiation(surplus / LibCommon.HUNDRED_PERCENT, _occupancy.congestionExponent);

        // Multiply base fee (wei/sec) with exponentResult and downscale by DECIMAL
        uint256 acf = (uint256(_occupancy.congestionBaseFeeWeiPerSec) * exponentResult) / DECIMAL;

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
            // Only square if another bit remains to consume — the value produced by
            // squaring after the last bit is never used, so skip that computation.
            if (_exponent > 0) {
                baseScaled = (baseScaled * baseScaled) / DECIMAL;
            }
        }

        return resultScaled - DECIMAL;      // subtract 1
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::: CONGESTION OF A CYCLE OCCUPANCY ::::::::::::::::::::::::::::::::::::::::::::::::::
    //
    // The congestion of a cycle is measured on the gas and on the task count its user tasks committed,
    // each as a share of its limit, in percent scaled by DECIMAL and counted as at most 100%. The
    // congestion fee is priced on the surplus of the larger share over the threshold
    // (congestionSurplus) and the billed-gas ramp on the surplus of the task share
    // (congestionSurplusByTasks); both apply only while isCongestionPriced.

    /// @notice Whether congestion is priced for the cycle: a threshold below 100% and a non-zero
    /// congestion base fee. Otherwise there is no congestion fee and no billed-gas ramp.
    function isCongestionPriced(CycleOccupancy memory _occupancy) internal pure returns (bool) {
        return _occupancy.congestionThresholdPercentage < LibCommon.HUNDRED_PERCENT
            && _occupancy.congestionBaseFeeWeiPerSec != 0;
    }

    /// @notice The committed gas as a share of the gas cap, in percent scaled by DECIMAL, at most
    /// 100%.
    function congestionPercentageByGas(CycleOccupancy memory _occupancy) internal pure returns (uint256) {
        return percentageOf(_occupancy.committedGas, _occupancy.registryMaxGasCap);
    }

    /// @notice The committed task count as a share of the task capacity, in percent scaled by
    /// DECIMAL, at most 100%.
    function congestionPercentageByTasks(CycleOccupancy memory _occupancy) internal pure returns (uint256) {
        return percentageOf(_occupancy.committedTasks, _occupancy.taskCapacity);
    }

    /// @notice The congestion threshold in percent scaled by DECIMAL.
    function congestionThreshold(CycleOccupancy memory _occupancy) internal pure returns (uint256) {
        return uint256(_occupancy.congestionThresholdPercentage) * DECIMAL;
    }

    /// @notice How far the larger of the gas and task shares is above the threshold, in percent
    /// scaled by DECIMAL; zero at or below it.
    function congestionSurplus(CycleOccupancy memory _occupancy) internal pure returns (uint256) {
        return surplusOver(
            Math.max(_occupancy.congestionPercentageByGas(), _occupancy.congestionPercentageByTasks()),
            _occupancy.congestionThreshold()
        );
    }

    /// @notice How far the task share is above the threshold, in percent scaled by DECIMAL; zero at
    /// or below it.
    function congestionSurplusByTasks(CycleOccupancy memory _occupancy) internal pure returns (uint256) {
        return surplusOver(_occupancy.congestionPercentageByTasks(), _occupancy.congestionThreshold());
    }

    /// @notice `_part / _whole` in percent scaled by DECIMAL, counted as at most 100%. A zero
    /// `_whole` counts as no usage: {LibCommon.validateConfigParameters} refuses a zero gas cap or
    /// task capacity, so it occurs only for a limit no configuration has set.
    function percentageOf(uint256 _part, uint256 _whole) private pure returns (uint256) {
        if (_whole == 0) { return 0; }
        return Math.min((_part * HUNDRED_PERCENT_SCALED) / _whole, HUNDRED_PERCENT_SCALED);
    }

    /// @notice `_usage - _threshold` when the usage is above the threshold, zero otherwise.
    function surplusOver(uint256 _usage, uint256 _threshold) private pure returns (uint256) {
        return _usage > _threshold ? _usage - _threshold : 0;
    }

    /// @notice The gas a task is billed for in a cycle with occupancy `_occupancy`
    /// (Entropy-Foundation/smr-moonshot#4921).
    /// @dev A slot's worth of gas is `floorGas = registryMaxGasCap / taskCapacity`. While the task
    /// share `s = committedTasks / taskCapacity` is at or below the congestion threshold `T`, a
    /// task is billed its own `_maxGasAmount`. Above it, a task declaring less than `floorGas` is
    /// billed an additional part of the difference that grows linearly with the task share:
    ///
    ///     billed = g + (floorGas - g) * (s - T) / (1 - T)
    ///
    /// so the addition is zero at the threshold and the whole difference when every slot is
    /// taken, where a task declaring less than `floorGas` is billed exactly `floorGas`. A task
    /// declaring `floorGas` or more is always billed its own gas. The addition is part of
    /// congestion pricing and is disabled by what disables the congestion fee: a threshold of
    /// 100% or a zero congestion base fee.
    /// Worked example, `floorGas` 250,000, `T` 50%, `g` 77,000: billed 77,000 at a task share
    /// of 50%, 111,600 at 60%, 215,400 at 90% and 250,000 at 100%.
    /// The result depends only on `_occupancy`, so a fee recomputed during the cycle from the
    /// cycle's snapshot bills the same gas the transition charged for.
    /// @param _maxGasAmount The task's max gas amount.
    /// @param _occupancy Occupancy of the cycle the fee is for.
    function billedGas(uint128 _maxGasAmount, CycleOccupancy memory _occupancy) internal pure returns (uint128) {
        if (!_occupancy.isCongestionPriced()) { return _maxGasAmount; }

        // (s - T) in percent scaled by DECIMAL. Registration and ConfigFacet.updateConfigBuffer keep
        // the committed count within the cycle's capacity; the task share is counted as at most
        // 100%, so a count above it is billed as a full registry. A zero capacity has no share and
        // so no surplus.
        uint256 surplus = _occupancy.congestionSurplusByTasks();
        if (surplus == 0) { return _maxGasAmount; }

        uint256 floorGas = uint256(_occupancy.registryMaxGasCap) / _occupancy.taskCapacity;
        if (_maxGasAmount >= floorGas) { return _maxGasAmount; }

        // (floorGas - g) * (s - T) / (1 - T), with one rounding. isCongestionPriced keeps the
        // threshold below 100%, so the divisor is not zero, and the surplus is at most
        // 100% - threshold, so the addition is at most floorGas - g.
        uint256 addition =
            ((floorGas - _maxGasAmount) * surplus) / (HUNDRED_PERCENT_SCALED - _occupancy.congestionThreshold());
        // At most floorGas, which is at most registryMaxGasCap, a uint128.
        return uint128(_maxGasAmount + addition);
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
        uint128 _refundableFee,
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
    /// @dev _automationFeePerSec is expected to be base automation fee + congestion fee if any.
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

    /// @notice Refunds the deposit fee and any automation fees of the task.
    /// @param _automationFeePerSec The fee per second the current cycle was charged at.
    /// @param _occupancy The current cycle's occupancy, {currentCycleOccupancy}, read once by the
    /// caller for all the tasks it refunds.
    function refundTaskFees(
        uint64 _currentTime,
        uint64 _refundDuration, 
        uint128 _automationFeePerSec,
        CycleOccupancy memory _occupancy,
        TaskMetadataLW memory _task
    ) internal {
        RegistryState storage registryState = LibAppStorage.registryState();

        // Do not attempt fee refund if remaining duration is 0
        if (_task.taskState != LibCommon.TaskState.PENDING && _refundDuration != 0) {
            // The refund is for the current cycle, so the task is billed as the transition into
            // it charged it: against the cycle's occupancy snapshot.
            uint128 _refundFee = calculateTaskFee(
                _task.taskState,
                _task.expiryTime,
                _task.maxGasAmount,
                _refundDuration,
                _currentTime,
                _automationFeePerSec,
                _occupancy
            );
            ( , uint256 remainingCycleLockedFees) = safeFeeRefund(
                    _task.taskIndex,
                    _task.owner,
                    registryState.cycleLockedFees,
                    _refundFee
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

    /// @notice Refunds the deposit fee of the task and removes from the registry during cycle transition.
    /// @param _taskIndex Index of the task.
    /// @param _taskOwner Owner of the task.
    /// @param _refundableDeposit Refundable amount of deposit.
    /// @param _lockedDeposit Total locked deposit.
    /// @return refunded Whether the deposit was unlocked and transferred; when it was not, an error
    /// event of {safeDepositRefund} records why.
    function refundDepositAndDrop(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) internal returns (bool refunded) {
        // Check if task is UST
        if (LibAppStorage.registryState().tasks[_taskIndex].taskType == LibCommon.TaskType.GST) { revert ICoreFacet.RegisteredTaskInvalidType(); }

        // Remove task from the registry state
        LibCommon.removeTask(_taskIndex, _taskOwner, false, false);

        // Refund
        refunded = safeDepositRefund(
            _taskIndex,
            _taskOwner,
            _refundableDeposit,
            _lockedDeposit
        );
    }

    /// @notice Internally calls _refund, reverts if the balance is insufficient.
    function refund(address _to, uint128 _amount) internal {
        if (_amount == 0) return;
        AppStorage storage s = LibAppStorage.appStorage();
        
        address erc20Supra = s.erc20Supra;
        uint256 balance = IERC20(erc20Supra).balanceOf(address(this));
        if (balance < _amount) { revert ICoreFacet.InsufficientBalanceForRefund(); }
        _refund(erc20Supra, _to, _amount);
    }

    /// @notice Occupancy of the current cycle: the gas and task snapshots taken when the cycle
    /// started, measured against the active configuration. A stop, removal or suspension during
    /// the cycle recomputes the cycle's fees from it.
    function currentCycleOccupancy() internal view returns (CycleOccupancy memory) {
        RegistryState storage registryState = LibAppStorage.registryState();
        return committedOccupancy(registryState.gasCommittedForThisCycle, registryState.tasksCommittedForThisCycle);
    }

    /// @notice Occupancy `_committedGas` / `_committedTasks` measured against the active
    /// configuration. The transition into a cycle charges against it after applying the config
    /// buffer, so it is the active configuration of the cycle being entered.
    function committedOccupancy(
        uint128 _committedGas,
        uint32 _committedTasks
    ) internal view returns (CycleOccupancy memory) {
        Config storage activeConfig = LibAppStorage.activeConfig();
        return occupancyWithActiveFees(
            _committedGas, _committedTasks, activeConfig.registryMaxGasCap, activeConfig.taskCapacity
        );
    }

    /// @notice An occupancy measured against `_registryMaxGasCap` and `_taskCapacity`, priced with
    /// the active configuration's fee parameters.
    function occupancyWithActiveFees(
        uint128 _committedGas,
        uint32 _committedTasks,
        uint128 _registryMaxGasCap,
        uint16 _taskCapacity
    ) private view returns (CycleOccupancy memory) {
        Config storage activeConfig = LibAppStorage.activeConfig();
        return CycleOccupancy({
            committedGas: _committedGas,
            committedTasks: _committedTasks,
            registryMaxGasCap: _registryMaxGasCap,
            taskCapacity: _taskCapacity,
            congestionThresholdPercentage: activeConfig.congestionThresholdPercentage,
            congestionExponent: activeConfig.congestionExponent,
            automationBaseFeeWeiPerSec: activeConfig.automationBaseFeeWeiPerSec,
            congestionBaseFeeWeiPerSec: activeConfig.congestionBaseFeeWeiPerSec
        });
    }

    /// @notice The current cycle's occupancy and the fee per second it yields, for a call that
    /// prices several of the cycle's tasks.
    function currentCyclePricing() internal view returns (CyclePricing memory pricing) {
        pricing.occupancy = currentCycleOccupancy();
        pricing.automationFeePerSec = calculateAutomationFeeMultiplierForCycle(pricing.occupancy);
    }

    /// @notice Calculates the automation fee multiplier for current cycle. 
    function calculateAutomationFeeMultiplierForCurrentCycle() internal view returns (uint128) {
        return calculateAutomationFeeMultiplierForCycle(currentCycleOccupancy());
    }

    /// @notice Calculates the automation fee per second for a cycle to which USTs have committed
    /// `_totalCommittedMaxGas` gas and `_totalCommittedTasks` tasks, under the active registry
    /// fee parameters, max gas cap and task capacity.
    function calculateAutomationFeeMultiplierForCommittedOccupancy(
        uint128 _totalCommittedMaxGas,
        uint32 _totalCommittedTasks
    ) internal view returns (uint128) {
        return calculateAutomationFeeMultiplierForCycle(
            committedOccupancy(_totalCommittedMaxGas, _totalCommittedTasks)
        );
    }

    /// @notice Estimates the fee for the next cycle of a task of `_taskOccupancy` max gas joining
    /// USTs that have committed `_committedOccupancy` gas and `_committedTasks` tasks to it,
    /// over the current cycle interval.
    /// @dev The occupancy is measured against the next cycle's max gas cap and task capacity and
    /// priced with the active fee parameters, as the Move registry's estimate is. The two limits
    /// are taken from the next cycle because `ConfigFacet.updateConfigBuffer` guards them against
    /// the registry's current commitment, so they are the limits the task joins. The fee
    /// parameters, the threshold and the cycle duration are set independently of the registry's
    /// state and can be buffered again before the cycle ends, so the estimate uses the ones in
    /// force when it is made.
    /// The transition charges against the occupancy committed when the cycle ends and the
    /// configuration applied at that boundary. The charge therefore equals this estimate when
    /// neither changes after the registration; a later registration or a buffered change of the
    /// fee parameters can make it differ.
    /// `_committedOccupancy` and `_committedTasks` exclude the task being estimated, which is
    /// added here.
    function estimateAutomationFeeWithCommittedOccupancyInternal(
        uint128 _taskOccupancy,
        uint128 _committedOccupancy,
        uint32 _committedTasks
    ) internal view returns (uint128) {
        AppStorage storage s = LibAppStorage.appStorage();
        RegistryState storage registryState = LibAppStorage.registryState();

        // The count is an external input; it is added to in uint256 and counted as at most
        // type(uint32).max, a share {billedGas} and the congestion fee count as 100% for any
        // capacity.
        CycleOccupancy memory nextCycleOccupancy = occupancyWithActiveFees(
            _taskOccupancy + _committedOccupancy,
            uint32(Math.min(uint256(_committedTasks) + 1, type(uint32).max)),
            registryState.nextCycleRegistryMaxGasCap,
            registryState.nextCycleTaskCapacity
        );

        uint128 automationFeePerSec = calculateAutomationFeeMultiplierForCycle(nextCycleOccupancy);

        if (automationFeePerSec == 0) return 0;
        return calculateAutomationFeeForInterval(
            s.durationSecs,
            billedGas(_taskOccupancy, nextCycleOccupancy),
            automationFeePerSec,
            nextCycleOccupancy.registryMaxGasCap
        );
    }

    /// @notice Helper function to unlock locked deposit and cycle fees when a task is stopped by its owner or removed by
    /// the VM signer. Calculates cycle fee and deposit fee that needs to be refunded. Tries to unlock the same from
    /// corresponding counters and returns the refund amounts. Function reverts if unlocking fails. Note that this
    /// function does not do actual refund, but only unlocking.
    /// @dev The amount unlocked from `cycleLockedFees` is the task's whole fee for the current cycle whatever the refund
    /// policy; only the share of it paid back to the owner depends on `_policy`.
    /// @param _policy PARTIAL: the owner gets half of the fee for the remaining cycle time and the whole deposit (half of
    /// the deposit for a PENDING task), which `stopTasks`, `removeTasks` and an ERROR removal apply. FULL: the owner gets
    /// the whole fee for the remaining cycle time and the whole deposit, which a CONFIG_UPDATE removal applies (#4087).
    /// See {LibCommon.RefundPolicy}.
    /// @param _pricing The current cycle's occupancy and fee per second, {currentCyclePricing}.
    /// Unused for a PENDING task, which was not charged for the cycle.
    function unlockDepositAndCycleFee(
        uint64 _taskIndex,
        LibCommon.TaskState _taskState,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _residualInterval,
        uint64 _currentTime,
        uint128 _depositFee,
        LibCommon.RefundPolicy _policy,
        CyclePricing memory _pricing
    )  internal returns (uint128, uint128) {
        AppStorage storage s = LibAppStorage.appStorage();
        RegistryState storage registryState = LibAppStorage.registryState();

        uint128 cycleLockedFeeForTask;
        uint128 cycleFeeRefund;
        uint128 depositRefund;
        // The residual-time fee never exceeds the fee charged for the cycle, since the residual
        // window is a suffix of the charged one, so the InvalidCycleRefundFee invariant below holds
        // for FULL_REFUND_FACTOR as well.
        // The only place a refund policy becomes a divisor. Each policy is named, so a policy added
        // to LibCommon.RefundPolicy without a divisor of its own reverts here rather than paying
        // another policy's share. Both divisors are non-zero constants, so the divisions below
        // cannot revert.
        uint8 refundDivisor;
        if (_policy == LibCommon.RefundPolicy.FULL) {
            refundDivisor = FULL_REFUND_FACTOR;
        } else if (_policy == LibCommon.RefundPolicy.PARTIAL) {
            refundDivisor = REFUND_FACTOR;
        } else {
            revert IRegistryFacet.UnsupportedRefundPolicy();
        }

        if (_taskState != LibCommon.TaskState.PENDING) {
            // The fee charged for the current cycle is recomputed from the cycle's occupancy
            // snapshot, the same inputs the transition charged with, so the amount unlocked from
            // cycleLockedFees is the amount that was locked for the task. The residual-time fee
            // bills the same gas.
            CycleOccupancy memory occupancy = _pricing.occupancy;
            uint128 automationFeePerSec = _pricing.automationFeePerSec;
            uint64 chargedDuration = 0;
            if (_expiryTime > s.startTime) {
                chargedDuration = uint64(Math.min(_expiryTime - s.startTime, s.durationSecs));
            }
            uint128 taskFeeForCurrentCycle = calculateAutomationFeeForInterval(
                chargedDuration,
                billedGas(_maxGasAmount, occupancy),
                automationFeePerSec,
                occupancy.registryMaxGasCap
            );
            uint128 taskFeeForResidualTime = calculateTaskFee(
                _taskState,
                _expiryTime,
                _maxGasAmount,
                _residualInterval,
                _currentTime,
                automationFeePerSec,
                occupancy
            );

            // Refund the full deposit and the remaining run-time fee divided by refundDivisor when a task is in active
            // or cancelled stage.
            cycleLockedFeeForTask = taskFeeForCurrentCycle;
            cycleFeeRefund = taskFeeForResidualTime / refundDivisor;
            depositRefund = _depositFee;
        } else {
            cycleLockedFeeForTask = 0;
            cycleFeeRefund = 0;
            depositRefund = _depositFee / refundDivisor;
        }

        bool result = safeUnlockLockedDeposit(_taskIndex, _depositFee);
        if (!result) { revert IRegistryFacet.ErrorDepositRefund(); }

        if (cycleLockedFeeForTask < cycleFeeRefund) { revert IRegistryFacet.InvalidCycleRefundFee(); }

        (bool hasLockedFee, uint256 remainingCycleLockedFees ) = safeUnlockLockedCycleFee(registryState.cycleLockedFees, cycleLockedFeeForTask, _taskIndex);
        if (!hasLockedFee) { revert IRegistryFacet.ErrorCycleFeeRefund(); }

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
    /// @param _occupancy Occupancy of the cycle the fee is for; the task is billed {billedGas}.
    /// @return Calculated task fee for the interval the task will be active.
    function calculateTaskFee(
        LibCommon.TaskState _state,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _potentialFeeTimeframe,
        uint64 _currentTime,
        uint128 _automationFeePerSec,
        CycleOccupancy memory _occupancy
    ) internal pure returns (uint128) {
        if (_automationFeePerSec == 0) { return 0; }
        if (_expiryTime <= _currentTime) { return 0; }
        
        uint64 taskActiveTimeframe = _expiryTime - _currentTime;

        // If the task is a new task i.e. in Pending state, then it is charged always for
        // the input _potentialFeeTimeframe(which is cycle-interval),
        // For the new tasks which active-timeframe is less than cycle-interval
        // it would mean it is their first and only cycle and we charge the fee for entire cycle.
        // Note that although the new short tasks are charged for entire cycle, the refunding logic remains the same for
        // them as for the long tasks.
        // This way bad-actors will be discouraged to submit small and short tasks with big occupancy by blocking other
        // good-actors register tasks.
        uint64 actualFeeTimeframe; 
        if (_state == LibCommon.TaskState.PENDING) {
            actualFeeTimeframe = _potentialFeeTimeframe;
        } else {
            actualFeeTimeframe = taskActiveTimeframe < _potentialFeeTimeframe ? taskActiveTimeframe : _potentialFeeTimeframe;
        }

        return calculateAutomationFeeForInterval(
            actualFeeTimeframe,
            billedGas(_maxGasAmount, _occupancy),
            _automationFeePerSec,
            _occupancy.registryMaxGasCap
        );
    }
}