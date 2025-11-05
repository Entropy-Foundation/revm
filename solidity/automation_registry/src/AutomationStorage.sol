
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EnumerableSet} from "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

// Helper library to used by AutomationRegistry and AutomationController.
library AutomationStorage {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Enum describing task type.
    enum TaskType {
        UST,
        GST
    }

    /// @notice Enum describing state of the cycle.
    enum CycleState {
        READY,
        STARTED,
        FINISHED,
        SUSPENDED
    }

    /// @notice Enum describing state of a task.
    enum TaskState {
        PENDING,
        ACTIVE,
        CANCELLED
    }

    /// @notice Configuration parameters for the automation registry.
    struct RegistryConfig {
        uint64 taskDurationCapSecs;
        uint128 registryMaxGasCap;
        uint128 automationBaseFeeWeiPerSec;  // TO_DO: need to decide on the currency
        uint128 flatRegistrationFeeWei;      // TO_DO: need to decide on the currency
        uint8 congestionThresholdPercentage;
        uint128 congestionBaseFeeWeiPerSec;  // TO_DO: need to decide on the currency
        uint8 congestionExponent;
        uint16 userTaskCapacity;
        uint64 cycleDurationSecs;
        uint64 sysTaskDurationCapSecs;
        uint128 sysRegistryMaxGasCap;
        uint16 sysTaskCapacity;
        bool registrationEnabled;
        address controller;
    }

    /// @notice Tracks per-cycle automation state and task indexes for user tasks.
    struct RegistryState {
        uint64 currentIndex;
        uint16 totalUserTasks;
        uint128 gasCommittedForNextCycle;
        uint128 gasCommittedForThisCycle;
        EnumerableSet.UintSet activeTaskIds;
        mapping(uint64 => TaskMetadata) tasks;   
        // mapping(address => uint64[]) userTasks       TO_DO: user to their tasks, need to decide on this 
    }

    /// @notice Tracks per-cycle automation state and task indexes for system tasks.
    struct RegistryStateSystemTasks {
        uint128 gasCommittedForNextCycle;
        uint128 gasCommittedForThisCycle;
        EnumerableSet.UintSet taskIds;
        EnumerableSet.AddressSet authorizedAccounts;
    }

    /// @notice Task metadata for individual automation tasks.
    struct TaskMetadata {
        uint64 taskIndex;
        address owner;
        bytes payloadTx;
        uint64 expiryTime;
        bytes32 txHash;
        uint128 maxGasAmount;
        uint128 gasPriceCap;
        uint128 automationFeeCapForCycle;
        bytes[] auxData;
        uint64 registrationTime;
        TaskState state;
        uint128 lockedFeeForNextCycle;
    }

    /// @notice Deposit and fee related accounting.
    struct Deposit {
        address coldWallet;
        uint256 totalDepositedAutomationFees;
        uint256 totalLockedFees;
        mapping(uint64 => uint256) taskLockedFees;
    }

    /// @notice Struct representing the state of current cycle.
    struct AutomationCycleInfo{
        uint64 index;
        CycleState state;
        uint64 startTime;
        uint64 durationSecs;
        TransitionState transitionState;
    }

    /// @notice Struct representing state transition information.
    struct TransitionState {
        uint64 refundDuration;
        uint64 newCycleDuration;
        uint128 automationFeePerSec;
        uint128 gasCommittedForNewCycle;
        uint128 gasCommittedForNextCycle;
        uint128 sysGasCommittedForNextCycle;
        uint128 lockedFees;
        EnumerableSet.UintSet expectedTasksToBeProcessed;
        uint64 nextTaskIndexPosition;
    }
}
