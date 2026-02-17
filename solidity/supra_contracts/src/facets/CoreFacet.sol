// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AppStorage} from "../libraries/LibAppStorage.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {LibCore} from "../libraries/LibCore.sol";
import {ICoreFacet} from "../interfaces/ICoreFacet.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

contract CoreFacet is ICoreFacet {
    /// @dev State variables
    AppStorage internal s;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: EVENTS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Emitted when automation is enabled.
    event AutomationEnabled(bool indexed status);
    
    /// @notice Emitted when automation is disabled.
    event AutomationDisabled(bool indexed status);
    
    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VM FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Called by the VM Signer on `AutomationBookkeepingAction::Process` action emitted by native layer ahead of the cycle transition.
    /// @param _cycleIndex Index of the cycle.
    /// @param _taskIndexes Array of task index to be processed.
    function processTasks(uint64 _cycleIndex, uint64[] memory _taskIndexes) external {
        // Check caller is VM Signer
        if (msg.sender != s.vmSigner) { revert CallerNotVmSigner(); }
        
        LibUtils.CycleState state = s.cycleState; 
        if (state == LibUtils.CycleState.FINISHED) {
            LibCore.onCycleTransition(_cycleIndex, _taskIndexes);
        } else {
            if (state != LibUtils.CycleState.SUSPENDED) { revert InvalidRegistryState(); }
            LibCore.onCycleSuspend(_cycleIndex, _taskIndexes);
        }
    }

    /// @notice Checks the cycle end and emit an event on it. Does nothing if SUPRA_NATIVE_AUTOMATION or SUPRA_AUTOMATION_V2 is disabled.
    function monitorCycleEnd() external {
        if (tx.origin != s.vmSigner) { revert CallerNotVmSigner(); }

        if (!LibCore.isCycleStarted() || LibCore.getCycleEndTime() > block.timestamp) {
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
        if (s.cycleState == LibUtils.CycleState.READY) {
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
        if (s.cycleState == LibUtils.CycleState.FINISHED && !LibCore.isTransitionInProgress()) {
            LibCore.tryMoveToSuspendedState();
        }

        emit AutomationDisabled(s.automationEnabled);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Returns the index, start time, duration and state of the current cycle. 
    function getCycleInfo() external view returns (uint64, uint64, uint64, LibUtils.CycleState) {
        return (s.index, s.startTime, s.durationSecs, s.cycleState);
    }

    /// @notice Returns the duration of the current cycle. 
    function getCycleDuration() external view returns (uint64) {
        return s.durationSecs;
    }

    /// @notice Returns the refund duration and automation fee per sec of the transtition state.
    /// @return Refund duration
    /// @return Automation fee per sec
    function getTransitionInfo() external view returns (uint64, uint128) {
        return (s.transitionState.refundDuration, s.transitionState.automationFeePerSec);
    }

    /// @notice Returns if automation is enabled.
    function isAutomationEnabled() external view returns (bool) {
        return s.automationEnabled;
    }
}
