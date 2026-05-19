// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AppStorage, LibAppStorage, TransitionState} from "../libraries/LibAppStorage.sol";
import {LibCommon} from "../libraries/LibCommon.sol";
import {LibCore} from "../libraries/LibCore.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {ICoreFacet} from "../interfaces/ICoreFacet.sol";
import {IFacetSelectors} from "../interfaces/IFacetSelectors.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract CoreFacet is ICoreFacet, IFacetSelectors {
    using LibUtils for address;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @dev State variables
    AppStorage internal s;
    
    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VM FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Called by the VM Signer on `AutomationBookkeepingAction::Process` action emitted by native layer ahead of the cycle transition.
    /// @param _cycleIndex Index of the cycle.
    /// @param _taskIndexes Array of task index to be processed.
    function processTasks(uint64 _cycleIndex, uint256[] memory _taskIndexes) external {
        // Check caller is VM Signer
        msg.sender.enforceIsVmSigner();
        
        LibCommon.CycleState state = s.cycleState; 
        if (state == LibCommon.CycleState.FINISHED) {
            LibCore.onCycleTransition(_cycleIndex, _taskIndexes);
        } else {
            if (state != LibCommon.CycleState.SUSPENDED) { revert InvalidRegistryState(); }
            LibCore.onCycleSuspend(_cycleIndex, _taskIndexes);
        }
    }

    /// @notice Checks the cycle end and emit an event on it. Does nothing if cycle is not in `STARTED` state.
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

        if (s.automationEnabled) { revert AlreadyEnabled(); }

        s.automationEnabled = true;
        if (s.cycleState == LibCommon.CycleState.READY) {
            LibCore.moveToStartedState();           
            LibCore.updateConfigFromBuffer();
        }

        emit AutomationEnabled(s.automationEnabled);
    }
    
    /// @notice Function to disable the automation.
    function disableAutomation() external {
        LibDiamond.enforceIsContractOwner();

        if (!s.automationEnabled) { revert AlreadyDisabled(); }
        
        s.automationEnabled = false;
        if (s.cycleState == LibCommon.CycleState.FINISHED && !LibCore.isTransitionInProgress()) {
            LibCore.tryMoveToSuspendedState();
        }

        emit AutomationDisabled(s.automationEnabled);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Returns the index, start time, duration and state of the current cycle. 
    function getCycleInfo() external view returns (uint64, uint64, uint64, LibCommon.CycleState) {
        return (s.index, s.startTime, s.durationSecs, s.cycleState);
    }

    /// @notice Returns the duration of the current cycle.
    function getCycleDuration() external view returns (uint64) {
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
    function getCycleStateDetails() external view returns (LibCommon.CycleDetails memory details)  {
        details.index = s.index;
        details.startTime = s.startTime;
        details.durationSecs = s.durationSecs;
        details.state = s.cycleState;
        TransitionState storage transitionState = LibAppStorage.transitionState();
        details.nextTaskIndexPosition = transitionState.nextTaskIndexPosition;
        details.expectedTasksToBeProcessed = LibUtils.uintSetToUint64Array(transitionState.expectedTasksToBeProcessed);
    }

    /// @notice Returns if automation is enabled.
    function isAutomationEnabled() external view returns (bool) {
        return s.automationEnabled;
    }

    /// @notice Removes registered tasks when predicate validation fails during runtime.
    /// @param _taskIndex index of the task that has a fatal error.
    /// @param _reason explained reason of task removal.
    function removeRegisteredTask(uint64 cycleIndex, uint64 _taskIndex, string memory _reason) external {
        msg.sender.enforceIsVmSigner();

        if (!s.automationEnabled) { return; }
        if (s.index != cycleIndex) { revert InvalidInputCycleIndex(); }

        uint64 cycleEndTime = LibCommon.getCycleEndTime();
        uint64 currentTime = uint64(block.timestamp);
        // Calculate refundable fee for this remaining time task in current cycle
        uint64 residualInterval = cycleEndTime <= currentTime ? 0 : (cycleEndTime - currentTime);

        LibCommon.RemovedTask memory rt = LibCore.handleTasksRemoval(_taskIndex, cycleEndTime, currentTime, residualInterval, _reason);
        emit TaskRemovedBySystem(rt);
    }


    function getSelectors() external pure override returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = CoreFacet.processTasks.selector;
        selectors[1] = CoreFacet.monitorCycleEnd.selector;
        selectors[2] = CoreFacet.enableAutomation.selector;
        selectors[3] = CoreFacet.disableAutomation.selector;
        selectors[4] = CoreFacet.removeRegisteredTask.selector;
        selectors[5] = CoreFacet.getCycleInfo.selector;
        selectors[6] = CoreFacet.getCycleDuration.selector;
        selectors[7] = CoreFacet.getTransitionInfo.selector;
        selectors[8] = CoreFacet.isAutomationEnabled.selector;
        selectors[9] = CoreFacet.getCycleStateDetails.selector;
    }
}
