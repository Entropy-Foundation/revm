// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {LibCommon} from "../libraries/LibCommon.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Struct representing Automation Registry configuration.
struct Config {
    uint128 registryMaxGasCap;
    uint128 sysRegistryMaxGasCap;
    uint128 automationBaseFeeWeiPerSec;                     // TO_DO: need to decide on the currency
    uint128 flatRegistrationFeeWei;                         // TO_DO: need to decide on the currency        
    uint128 congestionBaseFeeWeiPerSec;                     // TO_DO: need to decide on the currency
    uint64 taskDurationCapSecs; 
    uint64 sysTaskDurationCapSecs;
    uint64 cycleDurationSecs;
    uint16 taskCapacity;
    uint16 sysTaskCapacity;
    uint8 congestionThresholdPercentage;
    uint8 congestionExponent;
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
    EnumerableSet.UintSet expectedTasksToBeProcessed;
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
    EnumerableSet.UintSet activeTaskIds;
    EnumerableSet.UintSet taskIdList;
    EnumerableSet.UintSet sysTaskIds;
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
    address vmSigner;
    address erc20Supra;
    EnumerableSet.AddressSet authorizedAccounts;
    mapping(uint256 => Config) configuration;
    bool ifBufferExists;

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

    uint256 constant ACTIVE_CONFIG = 0;
    uint256 constant BUFFER_CONFIG = 1;
    uint256 constant TRANSITION_STATE = 0;
    uint256 constant REGISTRY_STATE = 0;

    function appStorage() internal pure returns (AppStorage storage s) {
        assembly {
            s.slot := 0
        }
    }

    function activeConfig() internal view returns (Config storage c) {
        AppStorage storage s = appStorage();
        c = s.configuration[ACTIVE_CONFIG];
    }

    function bufferConfig() internal view returns (Config storage c) {
        AppStorage storage s = appStorage();
        c = s.configuration[BUFFER_CONFIG];
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
