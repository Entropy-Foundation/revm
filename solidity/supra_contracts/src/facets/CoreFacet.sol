// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AppStorage, LibAppStorage, TransitionState} from "../libraries/LibAppStorage.sol";
import {LibCommon} from "../libraries/LibCommon.sol";
import {LibCore} from "../libraries/LibCore.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {ICoreFacet} from "../interfaces/ICoreFacet.sol";
import {IFacetSelectors} from "../interfaces/IFacetSelectors.sol";
import {IRegistryStatus} from "../interfaces/IRegistryStatus.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract CoreFacet is ICoreFacet, IFacetSelectors {
    using LibUtils for address;
    using EnumerableSet for EnumerableSet.UintSet;

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VM FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Called by the VM Signer on `AutomationBookkeepingAction::Process` action emitted by native layer ahead of the cycle transition.
    /// @dev The node's off-chain VM-signer decoder hardcodes this function's selector and calls
    ///      it every cycle transition. Do not Remove this selector via diamondCut post-genesis;
    ///      Replace (to ship a fix) is fine.
    /// @param _cycleIndex Index of the cycle.
    /// @param _taskIndexes Array of task index to be processed.
    function processTasks(uint64 _cycleIndex, uint256[] memory _taskIndexes) external {
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

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Returns the index, start time, duration and state of the current cycle. 
    function getCycleInfo() external view returns (uint64, uint64, uint64, LibCommon.CycleState) {
        AppStorage storage s = LibAppStorage.appStorage();
        return (s.index, s.startTime, s.durationSecs, s.cycleState);
    }

    /// @notice Returns the duration of the current cycle.
    function getCycleDuration() external view returns (uint64) {
        AppStorage storage s = LibAppStorage.appStorage();
        return s.durationSecs;
    }

    /// @notice Returns the refund duration and automation fee per sec of the transition state.
    /// @return Refund duration
    /// @return Automation fee per sec
    function getTransitionInfo() external view returns (uint64, uint128) {
        TransitionState storage transitionState = LibAppStorage.transitionState();
        return (transitionState.refundDuration, transitionState.automationFeePerSec);
    }

    /// @notice Returns the index, start time, duration, state, transition details if any of the current cycle.
    /// @dev Node's off-chain automation registry manager relies on existence of it.
    /// Update/Replace is acceptable,  but removal should be checked against node-runtime first.
    function getCycleStateDetails() external view returns (LibCommon.CycleDetails memory details)  {
        AppStorage storage s = LibAppStorage.appStorage();
        details.index = s.index;
        details.startTime = s.startTime;
        details.durationSecs = s.durationSecs;
        details.state = s.cycleState;
        TransitionState storage transitionState = LibAppStorage.transitionState();
        details.nextTaskIndexPosition = transitionState.nextTaskIndexPosition;
        details.expectedTasksToBeProcessed = LibUtils.uint256ArrayToUint64Array(transitionState.expectedTasksToBeProcessed);
    }

    /// @notice Returns if automation is enabled.
    function isAutomationEnabled() public view returns (bool) {
        return LibAppStorage.appStorage().automationEnabled;
    }

    /// @notice Returns true only if the Automation Registry is both fully initialized
    /// (see IRegistryStatus.isInitialized) and automation is currently enabled -- a single
    /// combined readiness check for callers (e.g. node-runtime) that need both facts before
    /// treating the registry as usable.
    /// @dev Calls isInitialized() through the diamond (address(this)), not a private copy of
    /// that check, so this always reflects whichever facet currently serves that selector --
    /// it can't drift out of sync after a future diamondCut replaces the loupe facet alone.
    /// Node's off-chain automation registry manager relies on existence of this function.
    /// Update/Replace is acceptable, but removal should be checked against node-runtime first.
    function isAutomationReadyEnabled() external view returns (bool) {
        return IRegistryStatus(address(this)).isInitialized() && isAutomationEnabled();
    }

    /// @notice Removes a registered task on the VM signer's request.
    /// @dev The node's off-chain VM-signer decoder hardcodes this function's selector and calls
    ///      it when a task fails at runtime, and when the EVM gas config of a new epoch no longer
    ///      admits an active task's transaction. Do not Remove this selector via diamondCut
    ///      post-genesis; Replace (to ship a fix) is fine.
    ///
    ///      ERROR removes the task (it must exist) and refunds half of the remaining current-cycle
    ///      fee and the whole deposit, or half the deposit for a PENDING task; it emits
    ///      TaskRemovedBySystem.
    ///
    ///      GAS_CONFIG_UPDATE removes the task only if it exists and the EVM gas config served by
    ///      {LibEvmGasConfig} for this block does not admit it, and is a no-op otherwise, so the
    ///      record stays correct if the figures change again between the node scheduling it and
    ///      its execution. It refunds the whole remaining current-cycle fee and the whole deposit,
    ///      nothing for a GST, and emits TaskRemovedByGasConfigUpdate (#4087).
    /// @param _cycleIndex index of the current cycle.
    /// @param _taskIndex index of the task to remove.
    /// @param _reason why the task is removed; selects the refund policy.
    /// @param _details human-readable description of the reason. It is carried in the record's
    ///      call data. For reason ERROR it is also logged, as the details field of the ABI-encoded
    ///      RemovedTask in TaskRemovedBySystem's log data; TaskRemovedByGasConfigUpdate does not
    ///      carry it.
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

        uint64 cycleEndTime = LibCommon.getCycleEndTime();
        uint64 currentTime = uint64(block.timestamp);
        // Calculate refundable fee for this remaining time task in current cycle
        uint64 residualInterval = cycleEndTime <= currentTime ? 0 : (cycleEndTime - currentTime);

        LibCore.handleTasksRemoval(_taskIndex, cycleEndTime, currentTime, residualInterval, _reason, _details);
    }


    function getSelectors() external pure override returns (bytes4[] memory selectors) {
        selectors = new bytes4[](11);
        selectors[0] = CoreFacet.processTasks.selector;
        selectors[1] = CoreFacet.monitorCycleEnd.selector;
        selectors[2] = CoreFacet.enableAutomation.selector;
        selectors[3] = CoreFacet.disableAutomation.selector;
        selectors[4] = CoreFacet.removeRegisteredTask.selector;
        selectors[5] = CoreFacet.getCycleInfo.selector;
        selectors[6] = CoreFacet.getCycleDuration.selector;
        selectors[7] = CoreFacet.getTransitionInfo.selector;
        selectors[8] = this.isAutomationEnabled.selector;
        selectors[9] = CoreFacet.getCycleStateDetails.selector;
        selectors[10] = CoreFacet.isAutomationReadyEnabled.selector;
    }
}
