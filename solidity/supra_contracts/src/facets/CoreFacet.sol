// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AppStorage, LibAppStorage, TransitionState} from "../libraries/LibAppStorage.sol";
import {LibCommon} from "../libraries/LibCommon.sol";
import {LibCore} from "../libraries/LibCore.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {ICoreFacet} from "../interfaces/ICoreFacet.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract CoreFacet is ICoreFacet {
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

    /// @notice Returns the index, start time, duration, state, transition details if any of the current cycle.
    function getCycleStateDetails() external view returns (LibCommon.CycleDetails memory details) {
        TransitionState storage transitionState = LibAppStorage.transitionState();
        
        details.index = s.index;
        details.startTime = s.startTime;
        details.durationSecs = s.durationSecs;
        details.state = s.cycleState;
        details.nextTaskIndexPosition = transitionState.nextTaskIndexPosition;
        details.expectedTasksToBeProcessed = transitionState.expectedTasksToBeProcessed.values();
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

    /// @notice Returns if automation is enabled.
    function isAutomationEnabled() external view returns (bool) {
        return s.automationEnabled;
    }

    /// @notice Removes registered tasks when predicate validation fails during runtime.
    /// @param _taskIndexes Array of task indexes that failed predicate validation.
    /// @param _reasons Array of reasons for task removal.
    function removeRegisteredTasks(uint64[] memory _taskIndexes, string[] memory _reasons) external {
        // Check caller is VM Signer
        msg.sender.enforceIsVmSigner();
        
        uint256 tasksCount = _taskIndexes.length;
        if (!s.automationEnabled || tasksCount == 0) { return; }
        if (tasksCount != _reasons.length) { revert InvalidArrayLength(); }
        uint64 cycleEndTime = LibCommon.getCycleEndTime();
        uint64 currentTime = uint64(block.timestamp);

        LibCommon.RemovedTask[] memory removedTasks = new LibCommon.RemovedTask[](tasksCount);    
        uint256 counter;

        // Calculate duration for refundable fee for the tasks in current cycle
        uint64 residualInterval = cycleEndTime <= currentTime ? 0 : (cycleEndTime - currentTime);
            
        for (uint256 i = 0; i < tasksCount; i++) {
            uint64 taskId = _taskIndexes[i];
            if (LibCommon.ifTaskExists(taskId)) {
                LibCommon.RemovedTask memory rt = LibCore.handleTasksRemoval(taskId, cycleEndTime, currentTime, residualInterval, _reasons[i]);
                removedTasks[counter++] = rt;
            }
        }

        if (counter > 0) {
            emit TasksRemovedBySystem(removedTasks);
        }
    }
}
