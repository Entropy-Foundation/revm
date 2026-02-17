// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// Helper library used by supra contracts
library LibUtils {

    // Custom errors
    error AddressCannotBeEOA();
    error AddressCannotBeZero();
    error InvalidTaskDuration();
    error InvalidRegistryMaxGasCap();
    error InvalidCongestionThreshold();
    error InvalidCongestionExponent();
    error InvalidTaskCapacity();
    error InvalidCycleDuration();
    error InvalidSysTaskDuration();
    error InvalidSysRegistryMaxGasCap();
    error InvalidSysTaskCapacity();
    
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
 
    /// @notice Struct representing a stopped task.
    struct TaskStopped {
        uint64 taskIndex;
        uint128 depositRefund;
        uint128 cycleFeeRefund;
        bytes32 txHash;
    }

    /// @notice Struct representing an entry in access list.
    struct AccessListEntry {
        address addr;
        bytes32[] storageKeys;
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

    /// @notice Helper function to validate the registry configuration parameters.
    function validateConfigParameters(
        uint64 _taskDurationCapSecs,
        uint128 _registryMaxGasCap,
        uint8 _congestionThresholdPercentage,
        uint8 _congestionExponent,
        uint16 _taskCapacity,
        uint64 _cycleDurationSecs,
        uint64 _sysTaskDurationCapSecs,
        uint128 _sysRegistryMaxGasCap,
        uint16 _sysTaskCapacity
    ) internal pure {
        if(_taskDurationCapSecs <= _cycleDurationSecs) { revert InvalidTaskDuration(); }
        if(_registryMaxGasCap == 0) { revert InvalidRegistryMaxGasCap(); }
        if(_congestionThresholdPercentage > 100) { revert InvalidCongestionThreshold(); }
        if(_congestionExponent == 0) { revert InvalidCongestionExponent(); }
        if(_taskCapacity == 0) { revert InvalidTaskCapacity(); }
        if(_cycleDurationSecs == 0) { revert InvalidCycleDuration(); }
        if(_sysTaskDurationCapSecs <= _cycleDurationSecs) { revert InvalidSysTaskDuration(); }
        if(_sysRegistryMaxGasCap == 0) { revert InvalidSysRegistryMaxGasCap(); }
        if(_sysTaskCapacity == 0) { revert InvalidSysTaskCapacity(); }
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
