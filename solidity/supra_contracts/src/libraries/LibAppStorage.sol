// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibCommon} from "../libraries/LibCommon.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Struct representing Automation Registry configuration.
struct Config {
    uint128 registryMaxGasCap;
    uint128 sysRegistryMaxGasCap;
    uint128 automationBaseFeeWeiPerSec;
    uint128 flatRegistrationFeeWei;
    uint128 congestionBaseFeeWeiPerSec;
    uint64 taskDurationCapSecs; 
    uint64 sysTaskDurationCapSecs;
    uint64 cycleDurationSecs;
    uint16 taskCapacity;
    uint16 sysTaskCapacity;
    uint8 congestionThresholdPercentage;
    uint8 congestionExponent;
    // Governance-set ceiling on congestionExponent, enforced by LibCommon.validateConfigParameters.
    // Raising congestionExponent above the current default (6) requires first raising this cap in
    // a separate governance action — deliberate friction on a parameter whose growth is exponential
    // (see LibAccounting.calculateExponentiation).
    uint8 maxCongestionExponent;
}

/// @notice Upper bounds on the sizes of a task's inputs, checked when the task registers
/// (LibRegistry).
struct DataLengthCaps {
    uint16 maxPayloadLength;
    uint16 maxPredicateLength;
    uint16 maxAuxDataLength; // total across all auxData entries combined
    uint16 maxAuxDataEntries; // bounds the array itself, independent of the byte total above
    /// Upper bound on the storage words a task admitted under these caps holds
    /// (`LibCommon.recordStoredWords`). Derived from the four caps and stored with them by
    /// `LibCommon.newDataLengthCaps`, so that applying caps at a cycle boundary does not
    /// recompute it.
    uint32 storedWords;
}

/// @notice Owner-set parameters that, with the benchmark-derived gas figures in `LibCommon`
/// (`RECORD_GAS_PER_TASK`, `RECORD_GAS_PER_STORED_WORD`, `RECORD_FINALIZATION_GAS_PER_TASK`),
/// size a `processTasks` bookkeeping record (`CoreFacet.getRecordMaxTaskCount`,
/// Entropy-Foundation/smr-moonshot#4755); see `LibCommon.recordMaxTaskCount` for the formula.
/// @dev The gas figures measure the code of the transition itself, so they change only with that
///      code, through a contract upgrade that re-runs `test/CycleTransitionGas.t.sol`. These two
///      parameters are the owner's levers that need no upgrade, both checked by
///      `LibCommon.validateRecordSizingParameters`.
struct RecordSizingParameters {
    /// Share, in percent, of a record's gas limit budgeted for its tasks and the finalization
    /// reserve, from 1 to `LibCommon.MAX_RECORD_TASK_SUPPORT_PERCENTAGE` (80). The rest covers
    /// what the gas figures do not model: the transaction's intrinsic gas, its calldata, and the
    /// variation of a task's cost around the figures. Lowering it shrinks every record
    /// uniformly, the lever for a record that runs short of gas before an upgrade can re-derive
    /// the figures. The Move registry applies a fixed 80%,
    /// `automation_registry::TASK_SUPPORT_FACTOR`.
    uint8 taskSupportPercentage;
    /// Largest registry capacity (`taskCapacity + sysTaskCapacity`) the gas figures were
    /// measured for. The finalization cost per task grows with the capacity, so
    /// `updateConfigBuffer` refuses a capacity above it; raising it is an owner declaration that
    /// the benchmark was re-run at that size and the figures still cover it.
    uint32 maxCapacity;
}

/// @notice Struct representing cycle state transition information.
struct TransitionState {
    uint256 lockedFees;
    uint128 automationFeePerSec;
    uint128 gasCommittedForNewCycle;
    uint128 gasCommittedForNextCycle;
    uint128 sysGasCommittedForNextCycle;
    uint64 refundDuration;
    uint64 newCycleDuration;
    uint64 nextTaskIndexPosition;
    // Plain array rather than EnumerableSet.UintSet: this field is only ever accessed
    // sequentially (push/length/index) and never via contains()/remove(), so the
    // EnumerableSet's second per-element SSTORE (the _positions membership mapping)
    // is pure overhead here — see LibCore.updateExpectedTasks. Elements are uint64 task IDs
    // (TaskMetadata.taskIndex), packed four per storage slot.
    uint64[] expectedTasksToBeProcessed;
    // Task IDs confirmed to survive this transition (appended incrementally by
    // LibCore.dropOrChargeTasks, one batch at a time), consumed directly by
    // LibCore.updateRegistryState to seed the new cycle's activeTaskIds without
    // re-scanning taskIdList from scratch at finalization. uint64 task IDs, four per slot.
    uint64[] survivedTaskIds;
}

/// @notice Task metadata for individual automation tasks.
struct TaskMetadata {
    uint128 maxGasAmount;
    uint128 gasPriceCap;        
    uint128 automationFeeCapForCycle;
    uint128 depositFee;
    bytes32 txHash;
    uint64 taskIndex;
    uint64 registrationTime;
    uint64 expiryTime;
    uint64 priority;
    address owner;
    LibCommon.TaskType taskType;
    LibCommon.TaskState taskState;
    bytes payloadTx;
    bytes predicate;
    bytes[] auxData;
}

/// @notice Lightweight projection of TaskMetadata for charging/lifecycle logic that
/// never reads payloadTx/predicate/auxData. Populating this instead of the full
/// TaskMetadata avoids copying those dynamic byte blobs from storage to memory.
struct TaskMetadataLW {
    uint128 maxGasAmount;
    uint128 gasPriceCap;
    uint128 automationFeeCapForCycle;
    uint128 depositFee;
    bytes32 txHash;
    uint64 taskIndex;
    uint64 expiryTime;
    address owner;
    LibCommon.TaskType taskType;
    LibCommon.TaskState taskState;
}

/// @notice Tracks per-cycle Automation Registry state and tasks related information.
struct RegistryState {
    uint256 cycleLockedFees;
    uint256 totalDepositedAutomationFees;
    uint128 gasCommittedForNextCycle;
    uint128 gasCommittedForThisCycle;
    uint128 sysGasCommittedForNextCycle;
    uint128 sysGasCommittedForThisCycle;
    uint128 nextCycleRegistryMaxGasCap;
    uint128 nextCycleSysRegistryMaxGasCap;

    uint64 currentIndex;
    // Plain array, not EnumerableSet.UintSet: no .contains() call site needs O(1)
    // arbitrary membership on this set anywhere in the codebase (only .add/.clear/
    // .length/.values previously), and it is now populated wholesale from
    // TransitionState.survivedTaskIds at cycle finalization — see LibCore.updateRegistryState.
    // Elements are uint64 task IDs, packed four per storage slot. taskIdList, sysTaskIds and
    // addressToTasks are EnumerableSet.UintSet, which holds uint256 values, so those lists and
    // the views that return them stay uint256 (#4285).
    uint64[] activeTaskIds;
    EnumerableSet.UintSet taskIdList;
    EnumerableSet.UintSet sysTaskIds;
    // Append-only mirror of taskIdList's insertion order (task IDs are assigned
    // strictly monotonically, so appending keeps this ascending by construction).
    // taskIdList's own iteration order is a separate, unrelated concern — see
    // LibCore.buildAliveOrderedTaskIds, which compacts this array at cycle end.
    // uint64 task IDs, four per slot.
    uint64[] orderedTaskIds;
    mapping(uint64 => TaskMetadata) tasks;
    mapping(address => EnumerableSet.UintSet) addressToTasks;
}

/// @notice Central AppStorage layout for Diamond proxy
struct AppStorage {

    // =============================================================
    //                      CONFIGURATION
    // =============================================================
    
    bool automationEnabled;
    bool registrationEnabled;
    /// @notice Address of the WrappedSupra token contract.
    address erc20Supra;
    EnumerableSet.AddressSet authorizedAccounts;
    mapping(uint256 => Config) configuration;
    bool ifBufferExists;

    /// @notice Owner-configurable upper bounds on task registration input sizes, double-buffered
    /// like `configuration`: the `ACTIVE_ENTRY` holds the caps in force
    /// (`LibAppStorage.activeDataLengthCaps`), and `ConfigFacet.updateDataLengthCaps` writes a
    /// change to the `BUFFER_ENTRY` (`LibAppStorage.bufferDataLengthCaps`), valid while
    /// `ifDataLengthCapsBufferExists`. The buffer applies at the next cycle boundary together with
    /// the config buffer (`LibCore.updateConfigFromBuffer`). Removing a task clears its stored
    /// data, so the caps also size `processTasks` records (Entropy-Foundation/smr-moonshot#4755);
    /// deferring a change to the boundary keeps a transition's record size fixed while it runs,
    /// and lets the transition that applies lower caps drop the tasks above them
    /// (LibCore.dropOrChargeTask).
    /// @dev Kept apart from `Config` rather than merged into it. The two are read in different
    /// phases: the caps only at registration, in the transition after they are lowered, and when
    /// they change; the config throughout accounting and every transition. Separate entries
    /// also mean applying one buffer copies only its own slots, and each setter keeps its own
    /// full-replacement semantics.
    mapping(uint256 => DataLengthCaps) dataLengthCaps;
    /// @notice Whether the `BUFFER_ENTRY` of `dataLengthCaps` holds caps waiting for the next
    /// cycle boundary.
    bool ifDataLengthCapsBufferExists;

    /// @notice Upper bound on the storage words of payload, predicate and auxData any task in
    /// the registry holds (`LibCommon.recordStoredWords`), which `CoreFacet.getRecordMaxTaskCount`
    /// sizes records with. It is the bound of the caps in force, except during the transition
    /// that applies lower caps: the tasks registered under the higher caps are still in the
    /// registry until that transition drops them, so the bound stays at the higher caps until
    /// it finalizes (`LibCore.resetTaskStoredWordsBound`).
    uint32 taskStoredWordsBound;
    /// @notice Set when the caps applied at a cycle boundary are lower than the previous ones in
    /// any field, and cleared when that transition finalizes. While set, the transition checks
    /// each task's stored data against the caps in force and drops a task above them; while
    /// clear, every task is known to be within the caps and the check is skipped.
    bool dataLengthCapsLowered;

    /// @notice Whether the `BUFFER_ENTRY` of `recordSizingParameters` holds
    /// parameters waiting for the next cycle boundary.
    /// @dev Declared before the mapping so that it packs into the slot of the data-length caps
    ///      flags, which `LibCore.updateConfigFromBuffer` reads at the same boundary.
    bool ifRecordSizingParametersBufferExists;

    /// @notice Owner-configurable parameters from which, with the gas figures in `LibCommon`,
    /// `CoreFacet.getRecordMaxTaskCount` derives how many tasks one `processTasks` bookkeeping
    /// record may carry (Entropy-Foundation/smr-moonshot#4755); see `RecordSizingParameters`.
    /// Double-buffered like `configuration` and `dataLengthCaps`:
    /// the `ACTIVE_ENTRY` holds the parameters in force
    /// (`LibAppStorage.activeRecordSizingParameters`), and
    /// `ConfigFacet.updateRecordSizingParameters` writes a change to the
    /// `BUFFER_ENTRY` (`LibAppStorage.bufferRecordSizingParameters`), valid
    /// while `ifRecordSizingParametersBufferExists`. The buffer applies at the next cycle
    /// boundary together with the config and caps buffers (`LibCore.updateConfigFromBuffer`),
    /// before the node sizes that transition's records, so the record size stays fixed while a
    /// transition runs and a node restarting mid-transition computes the size its peers built
    /// the records with.
    mapping(uint256 => RecordSizingParameters) recordSizingParameters;

    // =============================================================
    //                      CYCLE MANAGEMENT
    // =============================================================

    /// @notice Current automation cycle and transition data
    uint64 index;
    uint64 startTime;
    uint64 durationSecs;
    LibCommon.CycleState cycleState;
    bool ifTransitionStateExists;
    mapping(uint256 => TransitionState) transitionState;

    // =============================================================
    //                      REGISTRY STATE
    // =============================================================

    /// @notice Registry and tasks state
    mapping(uint256 => RegistryState) registry;
}

/// @notice AppStorage accessor for Diamond facets
library LibAppStorage {

    /// @notice Keys of the two entries of every double-buffered setting (`configuration`,
    /// `dataLengthCaps`, `recordSizingParameters`): the value in force, and the value waiting
    /// for the next cycle boundary, where `LibCore.updateConfigFromBuffer` copies every pending
    /// buffer to its active entry in the same call.
    uint256 constant ACTIVE_ENTRY = 0;
    uint256 constant BUFFER_ENTRY = 1;
    uint256 constant TRANSITION_STATE = 0;
    uint256 constant REGISTRY_STATE = 0;

    // ERC-7201-style namespaced storage slot, mirroring LibDiamond.DIAMOND_STORAGE_POSITION's
    // own convention. Deliberately not slot 0: Solidity's automatic sequential storage layout
    // starts every contract's first declared state variable at slot 0, so a plain state
    // variable can never be made immune to a future facet's inherited storage (Ownable,
    // Pausable, Initializable, ERC20, etc.) landing there too — the only way to make
    // AppStorage's location independent of what any facet inherits is to pin it, via
    // assembly, to a slot nothing else's automatic layout will ever compute.
    //
    // Derivation: keccak256(abi.encode(uint256(keccak256("supra.automation.registry.appstorage")) - 1))
    //             & ~bytes32(uint256(0xff))
    bytes32 constant APP_STORAGE_POSITION = 0x1a8caa6e7a3f48200daaf7419e3bce8b119c3099bb3b75a9b1ba416f813ed500;

    function appStorage() internal pure returns (AppStorage storage s) {
        bytes32 position = APP_STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function activeConfig() internal view returns (Config storage c) {
        AppStorage storage s = appStorage();
        c = s.configuration[ACTIVE_ENTRY];
    }

    function bufferConfig() internal view returns (Config storage c) {
        AppStorage storage s = appStorage();
        c = s.configuration[BUFFER_ENTRY];
    }

    /// @notice The data-length caps in force (`AppStorage.dataLengthCaps`).
    function activeDataLengthCaps() internal view returns (DataLengthCaps storage c) {
        AppStorage storage s = appStorage();
        c = s.dataLengthCaps[ACTIVE_ENTRY];
    }

    /// @notice The data-length caps waiting for the next cycle boundary, valid while
    /// `AppStorage.ifDataLengthCapsBufferExists`.
    function bufferDataLengthCaps() internal view returns (DataLengthCaps storage c) {
        AppStorage storage s = appStorage();
        c = s.dataLengthCaps[BUFFER_ENTRY];
    }

    /// @notice The record sizing parameters in force (`AppStorage.recordSizingParameters`).
    function activeRecordSizingParameters() internal view returns (RecordSizingParameters storage p) {
        AppStorage storage s = appStorage();
        p = s.recordSizingParameters[ACTIVE_ENTRY];
    }

    /// @notice The record sizing parameters waiting for the next cycle boundary, valid while
    /// `AppStorage.ifRecordSizingParametersBufferExists`.
    function bufferRecordSizingParameters() internal view returns (RecordSizingParameters storage p) {
        AppStorage storage s = appStorage();
        p = s.recordSizingParameters[BUFFER_ENTRY];
    }

    function transitionState() internal view returns (TransitionState storage ts) {
        AppStorage storage s = appStorage();
        ts = s.transitionState[TRANSITION_STATE];
    }

    function registryState() internal view returns (RegistryState storage rs) {
        AppStorage storage s = appStorage();
        rs = s.registry[REGISTRY_STATE];
    }
}
