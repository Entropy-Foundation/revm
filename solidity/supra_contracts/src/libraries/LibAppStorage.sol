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
    mapping(address => EnumerableSet.UintSet) userTasks; 
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

    /// @notice Active registry configuration
    Config activeConfig;

    /// @notice Configuration buffer (for updates)
    bool ifBufferExists;
    Config configBuffer;             

    // =============================================================
    //                      CYCLE MANAGEMENT
    // =============================================================

    /// @notice Current automation cycle and transition data
    uint64 index;
    uint64 startTime;
    uint64 durationSecs;
    LibCommon.CycleState cycleState;
    bool ifTransitionStateExists;
    TransitionState transitionState;

    // =============================================================
    //                      REGISTRY STATE
    // =============================================================

    /// @notice Registry and tasks state
    RegistryState registryState;
}

/// @notice AppStorage accessor for Diamond facets
library LibAppStorage {
    function appStorage() internal pure returns (AppStorage storage s) {
        assembly {
            s.slot := 0
        }
    }
}
