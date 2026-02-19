// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {LibAccounting} from "./LibAccounting.sol";
import {LibCommon} from "./LibCommon.sol";
import {LibUtils} from "./LibUtils.sol";
import {AppStorage, LibAppStorage} from "./LibAppStorage.sol";

library LibRegistry {
    using LibUtils for *;

    /// @notice Address of the transaction hash precompile.
    address public constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000053555001;

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ERRORS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    error RegistrationDisabled();
    error AutomationNotEnabled();
    error CycleTransitionInProgress();
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

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: INTERNAL FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Read tx hash via precompile. Reverts if precompile missing/fails.
    function readTxHash() internal view returns (bytes32) {
        (bool ok, bytes memory out) = TX_HASH_PRECOMPILE.staticcall("");
        require(ok, FailedToCallTxHashPrecompile());
        require(out.length == 32, TxnHashLengthShouldBe32(uint64(out.length)));
        return abi.decode(out, (bytes32));
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

    function updateGasCommittedForNextCycle(LibCommon.TaskType _taskType, uint128 _maxGasAmount) internal {
        AppStorage storage s = LibAppStorage.appStorage();

        bool isUST = _taskType == LibCommon.TaskType.UST;

        uint128 gasCommittedForNextCycle = isUST ? s.registryState.gasCommittedForNextCycle : s.registryState.sysGasCommittedForNextCycle;
        if (gasCommittedForNextCycle < _maxGasAmount) { revert GasCommittedValueUnderflow(); }
       
        // Adjust the gas committed for the next cycle by subtracting the gas amount of the cancelled/stopped task
        if (isUST) {
            s.registryState.gasCommittedForNextCycle = gasCommittedForNextCycle - _maxGasAmount;
        } else {
            s.registryState.sysGasCommittedForNextCycle = gasCommittedForNextCycle - _maxGasAmount;
        }
    }

    /// @notice Helper function that performs validation and updates state for a valid task.
    function updateStateForValidRegistration(
        uint256 _totalTasks, 
        uint64 _regTime,
        uint64 _expiryTime,
        LibCommon.TaskType _taskType,
        bytes memory _payloadTx, 
        uint128 _maxGasAmount, 
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle
    ) internal {
        AppStorage storage s = LibAppStorage.appStorage();

        // Check if automation and registration is enabled
        if (!s.automationEnabled) { revert AutomationNotEnabled(); }
        if (!s.registrationEnabled) { revert RegistrationDisabled(); }

        if (!LibCommon.isCycleStarted()) { revert CycleTransitionInProgress(); }
        
        bool isUST = _taskType == LibCommon.TaskType.UST;
   
        uint64 taskDurationCap;
        uint128 gasCommittedForNextCycle;
        uint128 nextCycleRegistryMaxGasCap;
        if (isUST) {
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

        if (isUST) {
            s.registryState.gasCommittedForNextCycle = gasCommitted;
        } else {
            s.registryState.sysGasCommittedForNextCycle = gasCommitted;
        } 
    }
}
