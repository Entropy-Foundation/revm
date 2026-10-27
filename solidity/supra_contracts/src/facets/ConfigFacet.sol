// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AppStorage, Config, RegistryState, LibAppStorage, TaskMetadataLW} from "../libraries/LibAppStorage.sol";
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
    ///      The new capacity is also checked against the record gas figures: the call reverts with
    ///      `LibCommon.RecordBudgetTooSmall` if a `processTasks` record at the current
    ///      per-transaction cap could not carry a single task at the new capacity (see
    ///      `updateRecordGasParameters`).
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

        // A record at the current per-transaction cap must still carry a task once the new
        // capacity applies, since the finalizing record's reserve grows with the capacity
        // (LibCommon.recordMaxTaskCount, Entropy-Foundation/smr-moonshot#4755).
        LibCommon.requireRecordBudgetFits(
            LibCommon.currentRecordTaskGas(),
            s.recordFinalizationGasPerTask,
            uint256(_taskCapacity) + uint256(_sysTaskCapacity),
            s.recordTaskSupportPercentage
        );

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
        s.configuration[LibAppStorage.BUFFER_CONFIG] = configBuffer;
        s.ifBufferExists = true;

        registryState.nextCycleRegistryMaxGasCap = _registryMaxGasCap;
        registryState.nextCycleSysRegistryMaxGasCap = _sysRegistryMaxGasCap;

        emit ConfigBufferUpdated(configBuffer);
    }

    /// @notice Updates the task-registration input size caps. Takes effect immediately (unlike
    /// updateConfigBuffer) since these only gate new registrations, which are already blocked
    /// outside cycle state STARTED, so there's no mid-cycle-fairness reason to defer them.
    /// @param _maxPayloadLength Max length in bytes of a task's payloadTx; a multiple of 32
    /// (LibCommon.validateDataLengthCaps).
    /// @param _maxPredicateLength Max length in bytes of a task's predicate; a multiple of 32.
    /// @param _maxAuxDataLength Max combined length in bytes across all of a task's auxData entries.
    /// @param _maxAuxDataEntries Max number of entries in a task's auxData array, bounded
    /// independently of _maxAuxDataLength.
    /// @dev Reverts with `LibCommon.ChangeDuringTransition` unless the cycle is READY
    ///      or STARTED, since the caps size `processTasks` records
    ///      (`LibCommon.requireNoCycleTransition`), and with `LibCommon.RecordBudgetTooSmall` if,
    ///      under the new caps, a record at the current per-transaction cap could not carry a
    ///      single task (see `updateRecordGasParameters`).
    function updateDataLengthCaps(
        uint16 _maxPayloadLength,
        uint16 _maxPredicateLength,
        uint16 _maxAuxDataLength,
        uint16 _maxAuxDataEntries
    ) external {
        LibDiamond.enforceIsContractOwner();
        LibCommon.requireNoCycleTransition();
        LibCommon.validateDataLengthCaps(_maxPayloadLength, _maxPredicateLength);

        AppStorage storage s = LibAppStorage.appStorage();
        // A removed task clears what it stores, so larger caps make a task cost more in a
        // record; a record at the current per-transaction cap must still carry one
        // (LibCommon.recordMaxTaskCount, Entropy-Foundation/smr-moonshot#4755).
        uint256 taskGas = LibCommon.recordTaskGas(
            s.recordGasPerTask,
            s.recordGasPerStoredWord,
            LibCommon.recordStoredWords(_maxPayloadLength, _maxPredicateLength, _maxAuxDataLength, _maxAuxDataEntries)
        );
        LibCommon.requireRecordBudgetFits(
            taskGas, s.recordFinalizationGasPerTask, LibCommon.largestRecordCapacity(), s.recordTaskSupportPercentage
        );
        s.maxPayloadLength = _maxPayloadLength;
        s.maxPredicateLength = _maxPredicateLength;
        s.maxAuxDataLength = _maxAuxDataLength;
        s.maxAuxDataEntries = _maxAuxDataEntries;

        emit DataLengthCapsUpdated(_maxPayloadLength, _maxPredicateLength, _maxAuxDataLength, _maxAuxDataEntries);
    }

    /// @notice Updates the gas figures and the task-support percentage from which
    /// `CoreFacet.getRecordMaxTaskCount` sizes a `processTasks` bookkeeping record
    /// (Entropy-Foundation/smr-moonshot#4755). Takes effect immediately, and is accepted only
    /// outside a cycle transition: the node sizes a transition's records when the transition
    /// starts. The four are set together so that a change to the budget and to the costs it is
    /// spent on is checked, and applied, as one.
    /// @dev Reverts with `LibCommon.ChangeDuringTransition` unless the cycle is READY
    ///      or STARTED (`LibCommon.requireNoCycleTransition`), with
    ///      `LibCommon.InvalidRecordGasParameters` if any gas figure is zero or the percentage is
    ///      outside 1..100, and with
    ///      `LibCommon.RecordBudgetTooSmall` if a record at the current per-transaction cap could
    ///      not carry a single task under the current data-length caps. The capacity checked is
    ///      `LibCommon.largestRecordCapacity`, so the figures also hold once a buffered config
    ///      applies. The figures are derived from `test/CycleTransitionGas.t.sol`, which asserts
    ///      the defaults against measured gas.
    /// @param _recordGasPerTask Gas one task adds to a `processTasks` call apart from clearing
    /// its stored data.
    /// @param _recordGasPerStoredWord Gas per storage word of payload, predicate and auxData that
    /// removing a task clears.
    /// @param _recordFinalizationGasPerTask Gas, per task the registry can hold, that the call
    /// finalizing a FINISHED -> STARTED transition pays on top of its tasks.
    /// @param _recordTaskSupportPercentage Share, in percent (1..100), of a record's gas limit
    /// budgeted for its tasks and the finalization reserve; the rest is headroom for the
    /// transaction's intrinsic gas, its calldata, and costs the figures do not model.
    function updateRecordGasParameters(
        uint64 _recordGasPerTask,
        uint64 _recordGasPerStoredWord,
        uint64 _recordFinalizationGasPerTask,
        uint8 _recordTaskSupportPercentage
    ) external {
        LibDiamond.enforceIsContractOwner();
        LibCommon.requireNoCycleTransition();
        LibCommon.validateRecordGasParameters(
            _recordGasPerTask, _recordGasPerStoredWord, _recordFinalizationGasPerTask, _recordTaskSupportPercentage
        );

        AppStorage storage s = LibAppStorage.appStorage();
        uint256 taskGas = LibCommon.recordTaskGas(
            _recordGasPerTask,
            _recordGasPerStoredWord,
            LibCommon.recordStoredWords(s.maxPayloadLength, s.maxPredicateLength, s.maxAuxDataLength, s.maxAuxDataEntries)
        );
        LibCommon.requireRecordBudgetFits(
            taskGas, _recordFinalizationGasPerTask, LibCommon.largestRecordCapacity(), _recordTaskSupportPercentage
        );

        s.recordGasPerTask = _recordGasPerTask;
        s.recordGasPerStoredWord = _recordGasPerStoredWord;
        s.recordFinalizationGasPerTask = _recordFinalizationGasPerTask;
        s.recordTaskSupportPercentage = _recordTaskSupportPercentage;

        emit RecordGasParametersUpdated(
            _recordGasPerTask, _recordGasPerStoredWord, _recordFinalizationGasPerTask, _recordTaskSupportPercentage
        );
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

    /// @notice Returns the current task-registration input size caps.
    function getDataLengthCaps() external view returns (uint16 maxPayloadLength, uint16 maxPredicateLength, uint16 maxAuxDataLength, uint16 maxAuxDataEntries) {
        AppStorage storage s = LibAppStorage.appStorage();
        maxPayloadLength = s.maxPayloadLength;
        maxPredicateLength = s.maxPredicateLength;
        maxAuxDataLength = s.maxAuxDataLength;
        maxAuxDataEntries = s.maxAuxDataEntries;
    }

    /// @notice Returns the gas figures and the task-support percentage that size a
    /// `processTasks` record.
    function getRecordGasParameters()
        external
        view
        returns (
            uint64 recordGasPerTask,
            uint64 recordGasPerStoredWord,
            uint64 recordFinalizationGasPerTask,
            uint8 recordTaskSupportPercentage
        )
    {
        AppStorage storage s = LibAppStorage.appStorage();
        recordGasPerTask = s.recordGasPerTask;
        recordGasPerStoredWord = s.recordGasPerStoredWord;
        recordFinalizationGasPerTask = s.recordFinalizationGasPerTask;
        recordTaskSupportPercentage = s.recordTaskSupportPercentage;
    }

    function getSelectors() external pure override returns (bytes4[] memory selectors) {
        selectors = new bytes4[](15);
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
        selectors[13] = ConfigFacet.updateRecordGasParameters.selector;
        selectors[14] = ConfigFacet.getRecordGasParameters.selector;
    }
}
