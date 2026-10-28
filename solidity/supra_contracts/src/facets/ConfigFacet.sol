// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AppStorage, Config, DataLengthCaps, RecordSizingParameters, RegistryState, LibAppStorage, TaskMetadataLW} from "../libraries/LibAppStorage.sol";
import {LibAccounting} from "../libraries/LibAccounting.sol";
import {LibCommon} from "../libraries/LibCommon.sol";
import {LibRegistry} from "../libraries/LibRegistry.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {IConfigFacet} from "../interfaces/IConfigFacet.sol";
import {IFacetSelectors} from "../interfaces/IFacetSelectors.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract ConfigFacet is IConfigFacet, IFacetSelectors {
    using EnumerableSet for *;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ADMIN FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Grants authorization to the input account to submit system automation tasks.
    /// It is foundation governance responsibility to make sure that the target is and instance of `MultiSignatureWallet`
    /// @param _account Address to grant authorization to.
    function grantAuthorization(address _account) external {
        LibDiamond.enforceIsContractOwner();

        AppStorage storage s = LibAppStorage.appStorage();
        require(s.authorizedAccounts.add(_account), AddressAlreadyExists());
        emit AuthorizationGranted(_account, block.timestamp);
    }

    /// @notice Revokes authorization from the input account to submit system automation tasks.
    /// @param _account Address to revoke authorization from.
    function revokeAuthorization(address _account) external {
        LibDiamond.enforceIsContractOwner();

        AppStorage storage s = LibAppStorage.appStorage();
        require(s.authorizedAccounts.remove(_account), AddressDoesNotExist());
        emit AuthorizationRevoked(_account, block.timestamp);
    }

    /// @notice Function to enable the task registration.
    function enableRegistration() external {
        LibDiamond.enforceIsContractOwner();

        AppStorage storage s = LibAppStorage.appStorage();
        if (s.registrationEnabled) { revert AlreadyEnabled(); }
        s.registrationEnabled = true;

        emit TaskRegistrationEnabled(s.registrationEnabled);
    }

    /// @notice Function to disable the task registration.
    function disableRegistration() external {
        LibDiamond.enforceIsContractOwner();

        AppStorage storage s = LibAppStorage.appStorage();
        if (!s.registrationEnabled) { revert AlreadyDisabled(); }
        s.registrationEnabled = false;

        emit TaskRegistrationDisabled(s.registrationEnabled);
    }

    /// @notice Removes the specified tasks, user and system alike, on the registry owner's
    /// request (#4636). Each task is removed exactly as if its owner had stopped it: the committed
    /// gas for the next cycle is reduced by its max gas amount, and a user task's owner is
    /// refunded the whole deposit and half of the remaining current-cycle fee, or half the deposit
    /// for a PENDING task. A system task is refunded nothing. The refund is paid to the task's
    /// owner. An index with no task is skipped and reported by `TaskRemovalByGovernanceSkipped`.
    /// Requires automation enabled and the cycle STARTED, as `stopTasks` does.
    /// @param _taskIndexes Indexes of the tasks to remove.
    function removeTasks(uint64[] memory _taskIndexes) external {
        LibDiamond.enforceIsContractOwner();
        LibRegistry.validateTaskIndexesInput(_taskIndexes);

        uint64 cycleEndTime = LibCommon.getCycleEndTime();
        uint64 currentTime = uint64(block.timestamp);
        uint64 residualInterval = cycleEndTime <= currentTime ? 0 : (cycleEndTime - currentTime);

        for (uint256 i = 0; i < _taskIndexes.length; i++) {
            uint64 taskId = _taskIndexes[i];
            if (!LibCommon.ifTaskExists(taskId)) {
                emit TaskRemovalByGovernanceSkipped(taskId);
                continue;
            }

            (LibCommon.TaskStopped memory removed, uint128 refund, TaskMetadataLW memory task) =
                LibRegistry.removeTaskByGovernance(taskId, cycleEndTime, currentTime, residualInterval);
            // Zero for a GST; LibAccounting.refund transfers nothing for a zero amount.
            LibAccounting.refund(task.owner, refund);

            emit TaskRemovedByGovernance(
                taskId, task.owner, task.taskType, removed.txHash, removed.depositRefund, removed.cycleFeeRefund
            );
        }
    }

    /// @notice Function to withdraw the accumulated fees.
    /// @param _amount Amount to withdraw.
    /// @param _recipient Address to withdraw fees to.
    function withdrawFees(uint256 _amount, address _recipient) external {
        LibDiamond.enforceIsContractOwner();

        if (_amount == 0) { revert InvalidAmount(); }
        LibUtils.validateAddress(_recipient);
        AppStorage storage s = LibAppStorage.appStorage();
        uint256 balance = IERC20(s.erc20Supra).balanceOf(address(this));

        if (balance < _amount) { revert InsufficientBalance(); }
        
        RegistryState storage registryState = LibAppStorage.registryState();
        if (balance - _amount < registryState.cycleLockedFees + registryState.totalDepositedAutomationFees) { revert RequestExceedsLockedBalance(); }

        bool sent = IERC20(s.erc20Supra).transfer(_recipient, _amount);
        if (!sent) { revert TransferFailed(); }

        emit RegistryFeeWithdrawn(_recipient, _amount);
    }

    /// @notice Function to update the registry configuration buffer.
    /// @dev `_taskCapacity` and `_sysTaskCapacity` bound how many tasks `CoreFacet.monitorCycleEnd()`
    ///      iterates over each cycle, so raising them raises that function's per-call gas cost.
    ///      `monitorCycleEnd()` is invoked once per block as a single registered entry in the
    ///      separate `BlockMeta` contract's `blockPrologue()` dispatch loop, under the fixed
    ///      per-entry gas limit it was registered with there (see `BlockMeta.getExecutionGasLimit`)
    ///      and `BlockMeta`'s own `blockPrologueGasCap`. This contract has no on-chain reference to
    ///      `BlockMeta` and intentionally does not cap `_taskCapacity`/`_sysTaskCapacity` against it,
    ///      so task-capacity growth stays possible without an upgrade here. That means increasing
    ///      these values is NOT automatically safe: before calling this with a higher capacity,
    ///      verify off-chain that the resulting worst-case `monitorCycleEnd()` gas cost still fits
    ///      under `BlockMeta`'s registered gas limit for it, or `blockPrologue()` will start
    ///      reverting/OOG-ing on that entry every block.
    ///      The new capacity is also checked against the record sizing parameters in force after
    ///      the next cycle boundary (see `updateRecordSizingParameters`): the call reverts with
    ///      `LibCommon.CapacityAboveRecordGasLimit` if it exceeds their `maxCapacity`, the capacity
    ///      the record gas figures were measured for, and with `LibCommon.RecordBudgetTooSmall` if
    ///      a `processTasks` record at the current per-transaction cap could not carry a single
    ///      task at the new capacity.
    function updateConfigBuffer(
        uint64 _taskDurationCapSecs,
        uint128 _registryMaxGasCap,
        uint128 _automationBaseFeeWeiPerSec,
        uint128 _flatRegistrationFeeWei,
        uint8 _congestionThresholdPercentage,
        uint128 _congestionBaseFeeWeiPerSec,
        uint8 _congestionExponent,
        uint8 _maxCongestionExponent,
        uint16 _taskCapacity,
        uint64 _cycleDurationSecs,
        uint64 _sysTaskDurationCapSecs,
        uint128 _sysRegistryMaxGasCap,
        uint16 _sysTaskCapacity
    ) external {
        LibDiamond.enforceIsContractOwner();

        AppStorage storage s = LibAppStorage.appStorage();
        LibCommon.validateConfigParameters(
            _taskDurationCapSecs,
            _registryMaxGasCap,
            _congestionThresholdPercentage,
            _congestionExponent,
            _maxCongestionExponent,
            _taskCapacity,
            _cycleDurationSecs,
            _sysTaskDurationCapSecs,
            _sysRegistryMaxGasCap,
            _sysTaskCapacity
        );

        requireRecordSizingFitsCapacity(uint256(_taskCapacity) + uint256(_sysTaskCapacity));

        RegistryState storage registryState = LibAppStorage.registryState();
        if (registryState.gasCommittedForNextCycle > _registryMaxGasCap) { revert UnacceptableRegistryMaxGasCap(); }
        if (registryState.sysGasCommittedForNextCycle > _sysRegistryMaxGasCap) { revert UnacceptableSysRegistryMaxGasCap(); }

        // Add new config to the buffer
        Config memory configBuffer = Config({ 
            registryMaxGasCap: _registryMaxGasCap, 
            sysRegistryMaxGasCap: _sysRegistryMaxGasCap, 
            automationBaseFeeWeiPerSec: _automationBaseFeeWeiPerSec, 
            flatRegistrationFeeWei: _flatRegistrationFeeWei, 
            congestionBaseFeeWeiPerSec: _congestionBaseFeeWeiPerSec, 
            taskDurationCapSecs: _taskDurationCapSecs, 
            sysTaskDurationCapSecs: _sysTaskDurationCapSecs, 
            cycleDurationSecs: _cycleDurationSecs, 
            taskCapacity: _taskCapacity, 
            sysTaskCapacity: _sysTaskCapacity, 
            congestionThresholdPercentage: _congestionThresholdPercentage,
            congestionExponent: _congestionExponent,
            maxCongestionExponent: _maxCongestionExponent
        });
        s.configuration[LibAppStorage.BUFFER_ENTRY] = configBuffer;
        s.ifBufferExists = true;

        registryState.nextCycleRegistryMaxGasCap = _registryMaxGasCap;
        registryState.nextCycleSysRegistryMaxGasCap = _sysRegistryMaxGasCap;

        emit ConfigBufferUpdated(configBuffer);
    }

    /// @dev Checks a capacity the registry is about to hold against the record sizing parameters
    ///      and stored-words bound in force after the next cycle boundary
    ///      (Entropy-Foundation/smr-moonshot#4755). The finalization cost per task grows with the
    ///      capacity, so the capacity must be within the one the gas figures were measured for,
    ///      and a record at the current per-transaction cap must still carry a task once the
    ///      finalizing record's reserve grows with it (LibCommon.requireRecordSizingFits). A
    ///      separate function keeps updateConfigBuffer's locals within the stack limit.
    function requireRecordSizingFitsCapacity(uint256 _capacity) private view {
        LibCommon.requireRecordSizingFits(
            LibCommon.nextRecordSizingParameters(), LibCommon.largestStoredWords(), _capacity
        );
    }

    /// @notice Buffers new task-registration input size caps, applied at the next cycle boundary
    /// together with the config buffer, like a config change. Registrations until then are
    /// checked against the caps in force. A second call before the boundary replaces the buffer.
    /// @dev Removing a task clears its stored data, so the caps size `processTasks` records
    ///      (`AppStorage.taskStoredWordsBound`, Entropy-Foundation/smr-moonshot#4755). When lower
    ///      caps apply, the transition that applies them drops every task stored above them, with
    ///      its deposit refunded (`LibCore.dropOrChargeTask`), and sizes its records for the
    ///      previous caps until it finalizes. Reverts with `LibCommon.RecordBudgetTooSmall` if,
    ///      once the buffers apply, a record at the current per-transaction cap could not carry a
    ///      single task with the record sizing parameters and capacity then in force (see
    ///      `updateRecordSizingParameters`).
    /// @param _maxPayloadLength Max length in bytes of a task's payloadTx; a multiple of 32
    /// (LibCommon.validateDataLengthCaps).
    /// @param _maxPredicateLength Max length in bytes of a task's predicate; a multiple of 32.
    /// @param _maxAuxDataLength Max combined length in bytes across all of a task's auxData entries.
    /// @param _maxAuxDataEntries Max number of entries in a task's auxData array, bounded
    /// independently of _maxAuxDataLength.
    function updateDataLengthCaps(
        uint16 _maxPayloadLength,
        uint16 _maxPredicateLength,
        uint16 _maxAuxDataLength,
        uint16 _maxAuxDataEntries
    ) external {
        LibDiamond.enforceIsContractOwner();
        LibCommon.validateDataLengthCaps(_maxPayloadLength, _maxPredicateLength);

        DataLengthCaps memory caps =
            LibCommon.newDataLengthCaps(_maxPayloadLength, _maxPredicateLength, _maxAuxDataLength, _maxAuxDataEntries);

        AppStorage storage s = LibAppStorage.appStorage();
        // Applying the caps raises the stored-words bound to theirs if theirs is larger
        // (LibCore.applyPendingDataLengthCaps), and the bound stays at least the current one until
        // a transition finalizes, so the larger of the two must leave room for a task.
        uint32 words = caps.storedWords;
        if (s.taskStoredWordsBound > words) { words = s.taskStoredWordsBound; }
        LibCommon.requireRecordSizingFits(LibCommon.nextRecordSizingParameters(), words, LibCommon.nextRecordCapacity());

        s.dataLengthCaps[LibAppStorage.BUFFER_ENTRY] = caps;
        s.ifDataLengthCapsBufferExists = true;

        emit DataLengthCapsBufferUpdated(caps);
    }

    /// @notice Buffers new owner-set parameters from which, with the benchmark-derived gas figures
    /// in `LibCommon`, `CoreFacet.getRecordMaxTaskCount` sizes a `processTasks` bookkeeping record
    /// (Entropy-Foundation/smr-moonshot#4755); see `RecordSizingParameters`. Like a config change,
    /// they apply at the next cycle boundary, before the node sizes that transition's records,
    /// and a second call before the boundary replaces the buffer.
    /// @dev Reverts with `LibCommon.InvalidRecordSizingParameters` if the percentage is zero or
    ///      above `LibCommon.MAX_RECORD_TASK_SUPPORT_PERCENTAGE`, or `maxCapacity` is zero
    ///      (`LibCommon.validateRecordSizingParameters`); with
    ///      `LibCommon.CapacityAboveRecordGasLimit` if `maxCapacity` is below the capacity in force
    ///      after the boundary; and with `LibCommon.RecordBudgetTooSmall` if a record at the
    ///      current per-transaction cap could not then carry a single task
    ///      (`LibCommon.requireRecordSizingFits`). The capacity and stored-words bound checked are
    ///      those after the boundary (`LibCommon.nextRecordCapacity`,
    ///      `LibCommon.largestStoredWords`), since the buffers apply together.
    ///      Raising `maxCapacity` declares that `test/CycleTransitionGas.t.sol` was re-run at that
    ///      capacity and that `LibCommon.RECORD_FINALIZATION_GAS_PER_TASK` covers the finalization
    ///      premium it measures. To raise the capacity above the current `maxCapacity`, buffer the
    ///      parameters first and then the config: both apply at the same boundary.
    /// @param _parameters The new record sizing parameters.
    function updateRecordSizingParameters(RecordSizingParameters calldata _parameters) external {
        LibDiamond.enforceIsContractOwner();
        LibCommon.validateRecordSizingParameters(_parameters);
        LibCommon.requireRecordSizingFits(_parameters, LibCommon.largestStoredWords(), LibCommon.nextRecordCapacity());

        AppStorage storage s = LibAppStorage.appStorage();
        s.recordSizingParameters[LibAppStorage.BUFFER_ENTRY] = _parameters;
        s.ifRecordSizingParametersBufferExists = true;

        emit RecordSizingParametersBufferUpdated(_parameters);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Returns the WrappedSupra token address.
    function erc20Supra() external view returns (address) {
        return LibAppStorage.appStorage().erc20Supra;
    }

    /// @notice Returns if task registration is enabled.
    function isRegistrationEnabled() external view returns (bool) {
        return LibAppStorage.appStorage().registrationEnabled;
    }

    /// @notice Returns the registry configuration.
    function getConfig() external view returns (Config memory) {
        return LibAppStorage.activeConfig();
    }

    /// @notice Returns the pending configuration.
    function getConfigBuffer() external view returns (Config memory) {
        return LibAppStorage.bufferConfig();
    }

    /// @notice Returns the task-registration input size caps in force.
    /// The same shape as `getDataLengthCapsBuffer`, including the caps' stored-words bound.
    function getDataLengthCaps() external view returns (DataLengthCaps memory) {
        return LibAppStorage.activeDataLengthCaps();
    }

    /// @notice Returns the data-length caps waiting for the next cycle boundary; all zero if none
    /// are buffered.
    function getDataLengthCapsBuffer() external view returns (DataLengthCaps memory) {
        return LibAppStorage.bufferDataLengthCaps();
    }

    /// @notice Returns the upper bound on the storage words any task in the registry holds, which
    /// `CoreFacet.getRecordMaxTaskCount` sizes records with (`AppStorage.taskStoredWordsBound`).
    function getTaskStoredWordsBound() external view returns (uint32) {
        return LibAppStorage.appStorage().taskStoredWordsBound;
    }

    /// @notice Returns the owner-set parameters in force that size a `processTasks` record.
    function getRecordSizingParameters() external view returns (RecordSizingParameters memory) {
        return LibAppStorage.activeRecordSizingParameters();
    }

    /// @notice Returns the record sizing parameters waiting for the next cycle boundary; all zero
    /// if none are buffered.
    function getRecordSizingParametersBuffer() external view returns (RecordSizingParameters memory) {
        return LibAppStorage.bufferRecordSizingParameters();
    }

    function getSelectors() external pure override returns (bytes4[] memory selectors) {
        selectors = new bytes4[](18);
        selectors[0] = ConfigFacet.grantAuthorization.selector;
        selectors[1] = ConfigFacet.revokeAuthorization.selector;
        selectors[2] = ConfigFacet.enableRegistration.selector;
        selectors[3] = ConfigFacet.disableRegistration.selector;
        selectors[4] = ConfigFacet.withdrawFees.selector;
        selectors[5] = ConfigFacet.updateConfigBuffer.selector;
        selectors[6] = ConfigFacet.erc20Supra.selector;
        selectors[7] = ConfigFacet.isRegistrationEnabled.selector;
        selectors[8] = ConfigFacet.getConfig.selector;
        selectors[9] = ConfigFacet.getConfigBuffer.selector;
        selectors[10] = ConfigFacet.updateDataLengthCaps.selector;
        selectors[11] = ConfigFacet.getDataLengthCaps.selector;
        selectors[12] = ConfigFacet.removeTasks.selector;
        selectors[13] = ConfigFacet.updateRecordSizingParameters.selector;
        selectors[14] = ConfigFacet.getRecordSizingParameters.selector;
        selectors[15] = ConfigFacet.getDataLengthCapsBuffer.selector;
        selectors[16] = ConfigFacet.getTaskStoredWordsBound.selector;
        selectors[17] = ConfigFacet.getRecordSizingParametersBuffer.selector;
    }
}
