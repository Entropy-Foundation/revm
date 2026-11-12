// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AppStorage, LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCommon} from "../libraries/LibCommon.sol";
import {LibCore} from "../libraries/LibCore.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {ICoreFacet} from "../interfaces/ICoreFacet.sol";
import {IFacetSelectors} from "../interfaces/IFacetSelectors.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Cycle bookkeeping and automation enablement for the automation registry: the VM signer's
/// per-block and per-transition calls, and the owner's enable/disable switch.
/// @dev The registry's cycle-state views are served by CoreViewFacet
/// (Entropy-Foundation/smr-moonshot#4989), which keeps this facet's deployed bytecode clear of
/// EIP-170's 24,576-byte limit.
/// After that split this facet is still the largest contract in the genesis set (21,957 bytes
/// under the production profile, 2,619 bytes below the limit), and any change to it, or to a
/// library it inlines (LibCore, LibAccounting, LibCommon), can grow its deployed bytecode. A new
/// external function therefore belongs in a facet of its own rather than in this one. When a
/// change here would bring this facet close to the limit, the next step is to move
/// `removeRegisteredTask` and the removal paths it alone reaches into a separate facet, as the
/// views were moved to CoreViewFacet; the node calls it by selector through the diamond, so a
/// move keeps the selector unchanged.
contract CoreFacet is ICoreFacet, IFacetSelectors {
    using LibUtils for address;

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VM FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Called by the VM Signer on `AutomationBookkeepingAction::Process` action emitted by native layer ahead of the cycle transition.
    /// @dev The node's off-chain VM-signer decoder hardcodes this function's selector and calls
    ///      it every cycle transition. Do not Remove this selector via diamondCut post-genesis;
    ///      Replace (to ship a fix) is fine. The selector is 0x7f69c35c,
    ///      processTasks(uint64,uint64[]); the node's processTasksCall::SELECTOR must match it.
    /// @param _cycleIndex Index of the cycle.
    /// @param _taskIndexes Array of task index to be processed.
    function processTasks(uint64 _cycleIndex, uint64[] memory _taskIndexes) external {
        // Check caller is VM Signer
        msg.sender.enforceIsVmSigner();

        if (_taskIndexes.length == 0) { return; }

        AppStorage storage s = LibAppStorage.appStorage();
        LibCommon.CycleState state = s.cycleState;
        if (state == LibCommon.CycleState.FINISHED) {
            LibCore.onCycleTransition(_cycleIndex, _taskIndexes);
        } else {
            if (state != LibCommon.CycleState.SUSPENDED) { revert InvalidRegistryState(); }
            LibCore.onCycleSuspend(_cycleIndex, _taskIndexes);
        }
    }

    /// @notice Checks the cycle end and emit an event on it. Does nothing if cycle is not in `STARTED` state.
    /// @dev The node's off-chain VM-signer decoder hardcodes this function's selector and calls
    ///      it every block. Do not Remove this selector via diamondCut post-genesis; Replace (to
    ///      ship a fix) is fine.
    function monitorCycleEnd() external {
        tx.origin.enforceIsVmSigner();

        if (!LibCommon.isCycleStarted() || LibCommon.getCycleEndTime() > block.timestamp) {
            return;
        }
        
        LibCore.onCycleEndInternal();
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ADMIN FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @notice Function to enable the automation.
    function enableAutomation() external {
        LibDiamond.enforceIsContractOwner();

        AppStorage storage s = LibAppStorage.appStorage();
        if (s.automationEnabled) { revert AlreadyEnabled(); }

        s.automationEnabled = true;
        if (s.cycleState == LibCommon.CycleState.READY) {
            LibCore.updateConfigFromBuffer();
            LibCore.moveToStartedState();
        }

        emit AutomationEnabled(s.automationEnabled);
    }

    /// @notice Function to disable the automation.
    function disableAutomation() external {
        LibDiamond.enforceIsContractOwner();

        AppStorage storage s = LibAppStorage.appStorage();
        if (!s.automationEnabled) { revert AlreadyDisabled(); }

        s.automationEnabled = false;
        if (LibCommon.isCycleStarted() || (s.cycleState == LibCommon.CycleState.FINISHED && !LibCore.isTransitionInProgress())) {
            LibCore.tryMoveToSuspendedState();
        }
        emit AutomationDisabled(s.automationEnabled);
    }

    /// @notice Removes a registered task on the VM signer's request.
    /// @dev The node's off-chain VM-signer decoder hardcodes this function's selector and calls
    ///      it when a task fails at runtime, and when the EVM gas config of a new epoch no longer
    ///      admits an active task's transaction. Do not Remove this selector via diamondCut
    ///      post-genesis; Replace (to ship a fix) is fine.
    ///
    ///      Either reason is a no-op for a task that no longer exists; it emits
    ///      TaskRemovalSkipped. Such a task was removed before the record runs: by its owner or
    ///      the registry owner in an earlier user transaction, or by an earlier record. A record
    ///      runs before the user transactions of its block, and the node reschedules a record that
    ///      is not executed into a later block.
    ///
    ///      ERROR removes the task and refunds half of the remaining current-cycle fee and the
    ///      whole deposit; it emits TaskRemovedBySystem. The node schedules it only for a task it
    ///      executes, which is ACTIVE or CANCELLED.
    ///
    ///      CONFIG_UPDATE removes the task only if the EVM gas config served by
    ///      {LibEvmGasConfig} for this block does not admit it, and is a no-op otherwise, so the
    ///      record stays correct if the figures change again between the node scheduling it and
    ///      its execution. It refunds the whole remaining current-cycle fee and the whole deposit,
    ///      nothing for a GST, and emits TaskRemovedByConfigUpdate (#4087).
    /// @param _cycleIndex index of the current cycle.
    /// @param _taskIndex index of the task to remove.
    /// @param _reason why the task is removed; selects the refund policy.
    /// @param _details human-readable description of the reason. It is carried in the record's
    ///      call data. For reason ERROR it is also logged, as the details parameter in
    ///      TaskRemovedBySystem's log data; TaskRemovedByConfigUpdate does not carry it.
    function removeRegisteredTask(
        uint64 _cycleIndex,
        uint64 _taskIndex,
        LibCommon.TaskRemovalReason _reason,
        string memory _details
    ) external {
        msg.sender.enforceIsVmSigner();

        AppStorage storage s = LibAppStorage.appStorage();
        // Check if automation is enabled and cycle is started, else revert with invalid operation error.
        // This will give clear feedback to downstream users on requested action status.
        if (!s.automationEnabled || !LibCommon.isCycleStarted()) { revert InvalidOperationForCurrentCycleState(); }
        // If cycle index doesn't match, revert.
        if (s.index != _cycleIndex) { revert InvalidInputCycleIndex(); }

        LibCore.handleTasksRemoval(_taskIndex, _reason, _details);
    }


    function getSelectors() external pure override returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = CoreFacet.processTasks.selector;
        selectors[1] = CoreFacet.monitorCycleEnd.selector;
        selectors[2] = CoreFacet.enableAutomation.selector;
        selectors[3] = CoreFacet.disableAutomation.selector;
        selectors[4] = CoreFacet.removeRegisteredTask.selector;
    }
}
