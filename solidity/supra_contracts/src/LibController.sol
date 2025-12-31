
// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {EnumerableSet} from "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {LibCommonUtils} from "./LibCommonUtils.sol";

// Helper library used by AutomationController.
library LibController {
    
    uint256 private constant MAX_UINT128 = type(uint128).max;
    uint256 private constant MAX_UINT64 = type(uint64).max;
    uint256 private constant MAX_UINT8 = type(uint8).max;

    /// @notice Struct representing the state of current cycle.
    struct AutomationCycleInfo{
        // uint64 | uint64 | uint64 | CycleState | bool
        uint256 index_startTime_durationSecs_state_ifTransitionStateExists;
        TransitionState transitionState;
    }

    /// @notice Struct representing state transition information.
    struct TransitionState {
        uint256 lockedFees;
        // uint128 | uint128;
        uint256 automationFeePerSec_gasCommittedForNewCycle;
        // uint128 | uint128
        uint256 gasCommittedForNextCycle_sysGasCommittedForNextCycle;
        // uint64 | uint64 | uint64         
        uint256 refundDuration_newCycleDuration_nextTaskIndexPosition;
        EnumerableSet.UintSet expectedTasksToBeProcessed;
    }
   
    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: AutomationCycleInfo ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    function initializeCycle(
        AutomationCycleInfo storage _cycleInfo,
        uint64 _index,
        uint64 _startTime,
        uint64 _durationSecs,
        LibCommonUtils.CycleState _cycleState
    ) internal {
        _cycleInfo.index_startTime_durationSecs_state_ifTransitionStateExists = 
            (uint256(_index) << 192) |
            (uint256(_startTime) << 128) |
            (uint256(_durationSecs) << 64) |
            (uint256(_cycleState) << 56);
    }

    // index (uint64) | startTime (uint64) | durationSecs (uint64) | state (CycleState/uint8) | ifTransitionStateExists (bool) [stored at bit 55]
    function index(AutomationCycleInfo storage cycle) internal view returns (uint64) {
        return uint64(cycle.index_startTime_durationSecs_state_ifTransitionStateExists >> 192);
    }

    function startTime(AutomationCycleInfo storage cycle) internal view returns (uint64) {
        return uint64(cycle.index_startTime_durationSecs_state_ifTransitionStateExists >> 128);
    }

    function durationSecs(AutomationCycleInfo storage cycle) internal view returns (uint64) {
        return uint64(cycle.index_startTime_durationSecs_state_ifTransitionStateExists >> 64);
    }

    function state(AutomationCycleInfo storage cycle) internal view returns (LibCommonUtils.CycleState) {
        return LibCommonUtils.CycleState(uint8(cycle.index_startTime_durationSecs_state_ifTransitionStateExists >> 56));
    }

    function ifTransitionStateExists(AutomationCycleInfo storage cycle) internal view returns (bool) {
        return ((cycle.index_startTime_durationSecs_state_ifTransitionStateExists >> 55) & 1) != 0;
    }

    function setIndex(AutomationCycleInfo storage cycle, uint64 _index) internal {
        cycle.index_startTime_durationSecs_state_ifTransitionStateExists &= ~(MAX_UINT64 << 192);     // Clear old bits
        cycle.index_startTime_durationSecs_state_ifTransitionStateExists |= uint256(_index) << 192;   // Set new value
    }

    function setStartTime(AutomationCycleInfo storage cycle, uint64 _startTime) internal {
        cycle.index_startTime_durationSecs_state_ifTransitionStateExists &= ~(MAX_UINT64 << 128);
        cycle.index_startTime_durationSecs_state_ifTransitionStateExists |= uint256(_startTime) << 128;
    }

    function setDurationSecs(AutomationCycleInfo storage cycle, uint64 _durationSecs) internal {
        cycle.index_startTime_durationSecs_state_ifTransitionStateExists &= ~(MAX_UINT64 << 64);
        cycle.index_startTime_durationSecs_state_ifTransitionStateExists |= uint256(_durationSecs) << 64;
    }

    function setState(AutomationCycleInfo storage cycle, uint8 _state) internal {
        cycle.index_startTime_durationSecs_state_ifTransitionStateExists &= ~(MAX_UINT8 << 56);
        cycle.index_startTime_durationSecs_state_ifTransitionStateExists |= uint256(_state) << 56;
    }

    function setTransitionStateExists(AutomationCycleInfo storage cycle, bool exists) internal {
        cycle.index_startTime_durationSecs_state_ifTransitionStateExists &= ~(uint256(1) << 55);
        cycle.index_startTime_durationSecs_state_ifTransitionStateExists |= exists ? (uint256(1) << 55) : 0;
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: TransitionState ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    // automationFeePerSec (uint128) | gasCommittedForNewCycle (uint128)
    function automationFeePerSec(AutomationCycleInfo storage cycle) internal view returns (uint128) {
        return uint128(cycle.transitionState.automationFeePerSec_gasCommittedForNewCycle >> 128);
    }

    function gasCommittedForNewCycle(AutomationCycleInfo storage cycle) internal view returns (uint128) {
        return uint128(cycle.transitionState.automationFeePerSec_gasCommittedForNewCycle);
    }

    function setAutomationFeePerSec(AutomationCycleInfo storage cycle, uint128 fee) internal {
        cycle.transitionState.automationFeePerSec_gasCommittedForNewCycle &= MAX_UINT128;
        cycle.transitionState.automationFeePerSec_gasCommittedForNewCycle |= uint256(fee) << 128;
    }

    function setGasCommittedForNewCycle(AutomationCycleInfo storage cycle, uint128 gas) internal {
        cycle.transitionState.automationFeePerSec_gasCommittedForNewCycle &= MAX_UINT128 << 128;
        cycle.transitionState.automationFeePerSec_gasCommittedForNewCycle |= uint256(gas);
    }


    // gasCommittedForNextCycle (uint128) | sysGasCommittedForNextCycle (uint128)
    function gasCommittedForNextCycle(AutomationCycleInfo storage cycle) internal view returns (uint128) {
        return uint128(cycle.transitionState.gasCommittedForNextCycle_sysGasCommittedForNextCycle >> 128);
    }

    function sysGasCommittedForNextCycle(AutomationCycleInfo storage cycle) internal view returns (uint128) {
        return uint128(cycle.transitionState.gasCommittedForNextCycle_sysGasCommittedForNextCycle);
    }

    function setGasCommittedForNextCycle(AutomationCycleInfo storage cycle, uint128 gas) internal {
        cycle.transitionState.gasCommittedForNextCycle_sysGasCommittedForNextCycle &= MAX_UINT128;
        cycle.transitionState.gasCommittedForNextCycle_sysGasCommittedForNextCycle |= uint256(gas) << 128;
    }

    function setSysGasCommittedForNextCycle(AutomationCycleInfo storage cycle, uint128 sysGas) internal {
        cycle.transitionState.gasCommittedForNextCycle_sysGasCommittedForNextCycle &= MAX_UINT128 << 128;
        cycle.transitionState.gasCommittedForNextCycle_sysGasCommittedForNextCycle |= uint256(sysGas);
    }


    // refundDuration (uint64) | newCycleDuration (uint64) | nextTaskIndexPosition (uint64)
    function refundDuration(AutomationCycleInfo storage cycle) internal view returns (uint64) {
        return uint64(cycle.transitionState.refundDuration_newCycleDuration_nextTaskIndexPosition >> 192);
    }

    function newCycleDuration(AutomationCycleInfo storage cycle) internal view returns (uint64) {
        return uint64(cycle.transitionState.refundDuration_newCycleDuration_nextTaskIndexPosition >> 128);
    }

    function nextTaskIndexPosition(AutomationCycleInfo storage cycle) internal view returns (uint64) {
        return uint64(cycle.transitionState.refundDuration_newCycleDuration_nextTaskIndexPosition >> 64);
    }

    function setRefundDuration(AutomationCycleInfo storage cycle, uint64 refund) internal {
        TransitionState storage ts = cycle.transitionState;

        // clear bits 192–255 (upper 64 bits)
        ts.refundDuration_newCycleDuration_nextTaskIndexPosition &= ~(MAX_UINT64 << 192);
        ts.refundDuration_newCycleDuration_nextTaskIndexPosition |= uint256(refund) << 192;
    }

    function setNewCycleDuration(AutomationCycleInfo storage cycle, uint64 duration) internal {
        TransitionState storage ts = cycle.transitionState;

        // clear bits 128-191
        ts.refundDuration_newCycleDuration_nextTaskIndexPosition &= ~(MAX_UINT64 << 128);
        ts.refundDuration_newCycleDuration_nextTaskIndexPosition |= uint256(duration) << 128;
    }

    function setNextTaskIndexPosition(AutomationCycleInfo storage cycle, uint64 pos) internal {
        TransitionState storage ts = cycle.transitionState;

        // clear bits 64-127
        ts.refundDuration_newCycleDuration_nextTaskIndexPosition &= ~(MAX_UINT64 << 64);
        ts.refundDuration_newCycleDuration_nextTaskIndexPosition |= uint256(pos) << 64;
    }

    /// @notice Represents intermediate state of the registry on cycle change.
    struct IntermediateStateOfCycleChange {
        uint256 cycleLockedFees;
        uint128 gasCommittedForNextCycle;
        uint128 sysGasCommittedForNextCycle;
        uint64[] removedTasks;
    }

    /// @notice Struct representing transition result.
    struct TransitionResult {
        uint128 fees;
        uint128 gas;
        uint128 sysGas;
        bool isRemoved;
    }

    /// @notice Helper function to sort an array.
    /// @param arr Input array to sort.
    /// @return Returns the sorted array. 
    function sortUint64(uint64[] memory arr) internal pure returns (uint64[] memory) {
        uint256 length = arr.length;
        for (uint256 i = 0; i < length; i++) {
            for (uint256 j = 0; j < length - 1; j++) {
                if (arr[j] > arr[j + 1]) {
                    uint64 temp = arr[j];
                    arr[j] = arr[j + 1];
                    arr[j + 1] = temp;
                }
            }
        }
        return arr;
    }

    /// @notice Helper function to sort an array.
    /// @param arr Input array to sort.
    /// @return Returns the sorted array. 
    function sortUint256(uint256[] memory arr) internal pure returns (uint256[] memory) {
        uint256 length = arr.length;
        for (uint256 i = 0; i < length; i++) {
            for (uint256 j = 0; j < length - 1; j++) {
                if (arr[j] > arr[j + 1]) {
                    uint256 temp = arr[j];
                    arr[j] = arr[j + 1];
                    arr[j + 1] = temp;
                }
            }
        }
        return arr;
    }
}
