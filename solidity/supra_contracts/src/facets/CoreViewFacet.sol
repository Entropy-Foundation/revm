// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AppStorage, LibAppStorage, TransitionState} from "../libraries/LibAppStorage.sol";
import {LibCommon} from "../libraries/LibCommon.sol";
import {ICoreViewFacet} from "../interfaces/ICoreViewFacet.sol";
import {IFacetSelectors} from "../interfaces/IFacetSelectors.sol";
import {IRegistryStatus} from "../interfaces/IRegistryStatus.sol";

/// @notice Read-only view onto the automation registry's cycle state.
/// @dev A separate facet from CoreFacet (Entropy-Foundation/smr-moonshot#4989), as
/// RegistryViewFacet is from RegistryFacet (Entropy-Foundation/smr-moonshot#4101), to keep
/// CoreFacet's deployed bytecode clear of EIP-170's 24,576-byte limit. Any future fix to
/// CoreFacet, or to a library it inlines (LibCore, LibAccounting, LibCommon), redeploys a fresh
/// CoreFacet (Entropy-Foundation/smr-moonshot#2772), and that redeployment must also fit the
/// limit.
/// This facet inlines LibCommon (`recordMaxTaskCount`, `recordCapacity` and the `RECORD_GAS_*`
/// constants) and reads the AppStorage, TransitionState, Config and RecordSizingParameters
/// layouts through LibAppStorage, so a fix to any of those also redeploys and Replaces this
/// facet. The node calls `getCycleStateDetails`, `getRecordMaxTaskCount` and
/// `isAutomationReadyEnabled` through the diamond.
contract CoreViewFacet is ICoreViewFacet, IFacetSelectors {
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
        details.expectedTasksToBeProcessed = transitionState.expectedTasksToBeProcessed;
    }

    /// @notice Returns the number of tasks one `processTasks` bookkeeping record with gas limit
    /// `_recordGasLimit` may carry (Entropy-Foundation/smr-moonshot#4755). The node passes the
    /// gas limit it builds the record with, the epoch's per-transaction cap, and chunks a
    /// transition's tasks into records of this many tasks. The Move registry's counterpart is
    /// `automation_registry::get_record_max_task_count`.
    /// @dev The count is `LibCommon.recordMaxTaskCount` over the benchmark-derived gas figures in
    ///      `LibCommon`, the owner-set task-support percentage
    ///      (`ConfigFacet.updateRecordSizingParameters`), the registry's stored-words bound
    ///      (`AppStorage.taskStoredWordsBound`) and the active config's capacity. All are the
    ///      ones the transition runs under: `CoreFacet.monitorCycleEnd` applies buffered caps,
    ///      parameters and config before the transition's first `processTasks`, and keeps the
    ///      bound at the higher caps until a transition that applies lower caps has dropped the
    ///      tasks above them. Returns 0 when no record at this gas limit can carry a task, and
    ///      the node then pauses automation. Reverts with
    ///      `LibCommon.InvalidRecordSizingParameters` if the parameters were never set.
    ///      Node's off-chain automation registry manager relies on existence of this function.
    ///      Update/Replace is acceptable, but removal should be checked against node-runtime first.
    /// @param _recordGasLimit Gas limit of the record.
    function getRecordMaxTaskCount(uint64 _recordGasLimit) external view returns (uint64) {
        return LibCommon.recordMaxTaskCount(
            _recordGasLimit,
            LibAppStorage.activeRecordSizingParameters().taskSupportPercentage,
            LibAppStorage.appStorage().taskStoredWordsBound,
            LibCommon.recordCapacity(LibAppStorage.activeConfig())
        );
    }

    /// @notice Returns if automation is enabled.
    function isAutomationEnabled() external view returns (bool) {
        return automationEnabled();
    }

    /// @notice Returns true only if the Automation Registry is both fully initialized
    /// (see IRegistryStatus.isInitialized) and automation is currently enabled -- a single
    /// combined readiness check for callers (e.g. node-runtime) that need both facts before
    /// treating the registry as usable.
    /// @dev Calls isInitialized() through the diamond (address(this)), not a private copy of
    /// that check, so this always reflects whichever facet currently serves that selector --
    /// it can't drift out of sync after a future diamondCut replaces the loupe facet alone.
    /// This facet is reached through the diamond's delegatecall, so address(this) is the
    /// diamond.
    /// Node's off-chain automation registry manager relies on existence of this function.
    /// Update/Replace is acceptable, but removal should be checked against node-runtime first.
    function isAutomationReadyEnabled() external view returns (bool) {
        return IRegistryStatus(address(this)).isInitialized() && automationEnabled();
    }

    /// @dev The one definition of "automation is enabled" that isAutomationEnabled and
    ///      isAutomationReadyEnabled both report, so the two views cannot disagree on it.
    function automationEnabled() private view returns (bool) {
        return LibAppStorage.appStorage().automationEnabled;
    }

    function getSelectors() external pure override returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = CoreViewFacet.getCycleInfo.selector;
        selectors[1] = CoreViewFacet.getCycleDuration.selector;
        selectors[2] = CoreViewFacet.getTransitionInfo.selector;
        selectors[3] = CoreViewFacet.isAutomationEnabled.selector;
        selectors[4] = CoreViewFacet.getCycleStateDetails.selector;
        selectors[5] = CoreViewFacet.isAutomationReadyEnabled.selector;
        selectors[6] = CoreViewFacet.getRecordMaxTaskCount.selector;
    }
}
