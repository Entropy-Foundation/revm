// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {LibRegistry} from "./LibRegistry.sol";

// Helper library used by supra contracts
library CommonUtils {

    // Custom errors
    error AddressCannotBeEOA();
    error AddressCannotBeZero();
    
    // Address of the VM Signer: SUP0
    address constant VM_SIGNER = address(0x53555000);
    
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

    /// @notice Enum describing task type.
    enum TaskType {
        UST,
        GST
    }
    
    /// @notice Task details for individual automation tasks.
    struct TaskDetails {
        uint128 maxGasAmount;
        uint128 gasPriceCap;
        uint128 automationFeeCapForCycle;
        uint128 depositFee;
        bytes32 txHash;
        uint64 taskIndex;
        uint64 registrationTime;
        uint64 expiryTime;
        uint64 priority;
        TaskType taskType;
        TaskState state;
        address owner;
        bytes payloadTx;      
        bytes[] auxData;
    }

    /// @notice Cycle details
    struct CycleDetails {
        uint64 index;
        uint64 startTime;
        uint64 durationSecs;
        CycleState state;
        uint64 nextTaskIndexPosition;
        uint64[] expectedTasksToBeProcessed;
    }

    function getTaskDetails(LibRegistry.TaskMetadata storage t) internal view returns (TaskDetails memory details) {
        // --- Decode maxGasAmount (upper 128 bits) ---
        details.maxGasAmount = uint128(t.maxGasAmount_gasPriceCap >> 128);

        // --- Decode gasPriceCap (lower 128 bits) ---
        details.gasPriceCap = uint128(t.maxGasAmount_gasPriceCap);

        // --- Decode automationFeeCapForCycle (upper 128 bits) ---
        details.automationFeeCapForCycle = uint128(t.automationFeeCapForCycle_depositFee >> 128);

        // --- Decode depositFee (lower 128 bits) ---
        details.depositFee = uint128(t.automationFeeCapForCycle_depositFee);

        // --- Direct values ---
        details.txHash = t.txHash;
        details.payloadTx = t.payloadTx;
        details.auxData = t.auxData;

        // --- Decode packed uint256: taskIndex | registrationTime | expiryTime | priority ---
        details.taskIndex        = uint64(t.taskIndex_registrationTime_expiryTime_priority >> 192);
        details.registrationTime = uint64(t.taskIndex_registrationTime_expiryTime_priority >> 128);
        details.expiryTime       = uint64(t.taskIndex_registrationTime_expiryTime_priority >> 64);
        details.priority         = uint64(t.taskIndex_registrationTime_expiryTime_priority);

        // --- Decode packed uint256: owner | taskType | taskState ---
        details.owner = address(uint160(t.owner_type_state >> 96));
        details.taskType = TaskType(uint8(t.owner_type_state >> 88));
        details.state = TaskState(uint8(t.owner_type_state >> 80));
    }


    /// @notice Deposit and fee related accounting.
    struct Deposit {
        uint256 totalDepositedAutomationFees;
        address coldWallet;
        // mapping(uint64 => uint256) taskLockedFees;  // TO_DO
    }

    /// @notice Struct representing a stopped task.
    struct TaskStopped {
        uint64 taskIndex;
        uint128 depositRefund;
        uint128 cycleFeeRefund;
        bytes32 txHash;
    }

    /// @dev Returns a boolean indicating whether the given address is a contract or not.
    /// @param _addr The address to be checked.
    /// @return A boolean indicating whether the given address is a contract or not.
    function isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    /// @notice Validates a contract address.
    function validateContractAddress(address _contractAddr) internal view {
        if (_contractAddr == address(0)) { revert AddressCannotBeZero(); }
        if (!isContract(_contractAddr)) { revert AddressCannotBeEOA(); }
    }

    /// @notice Validates a contract address.
    function validateAddress(address _contractAddr) internal view {
        if (_contractAddr == address(0)) { revert AddressCannotBeZero(); }
    }

    /// @notice Checks if an address is VM Signer.
    /// @param _addr Address to check.
    /// @return bool If it is VM Signer.
    function isVmSigner(address _addr) internal pure returns (bool) {
        return _addr == VM_SIGNER;
    }

    /// @notice Checks if an address is a reserved address. 
    /// @param _addr Address to check.
    /// @return bool If it is a reserved address.
    function isReservedAddress(address _addr) internal pure returns (bool) {
        uint160 addr = uint160(_addr);
        return addr >= uint160(VM_SIGNER) && addr <= uint160(0x535550FF);
    }
}
