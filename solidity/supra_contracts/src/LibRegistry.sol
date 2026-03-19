
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {EnumerableSet} from "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {CommonUtils} from "./CommonUtils.sol";

// Helper library used by AutomationRegistry.
library LibRegistry {
    
    uint256 private constant MAX_UINT128 = type(uint128).max;
    uint256 private constant MAX_UINT160 = type(uint160).max;
    uint256 private constant MAX_UINT64 = type(uint64).max;
    uint256 private constant MAX_UINT8 = type(uint8).max;
    
    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: TaskMetadata ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Task metadata for individual automation tasks.
    struct TaskMetadata {
        // uint128 | uint128
        uint256 maxGasAmount_gasPriceCap;
        
        // uint128 | uint128
        uint256 automationFeeCapForCycle_depositFee;

        bytes32 txHash;
        
        // uint64 | uint64 | uint64 | uint64
        uint256 taskIndex_registrationTime_expiryTime_priority;

        // address | TaskType (uint8) | TaskState (uint8)
        uint256 owner_type_state;

        bytes payloadTx;      
        bytes[] auxData;
    }

    function createTaskMetadata(
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint128 _depositFee,
        bytes32 _txHash,
        uint64 _taskIndex,
        uint64 _registrationTime,
        uint64 _expiryTime,
        uint64 _priority,
        address _owner,
        CommonUtils.TaskType _type,
        CommonUtils.TaskState _state,
        bytes memory _payloadTx,
        bytes[] memory _auxData
    ) internal pure returns (TaskMetadata memory t) {
        // Pack (uint128 | uint128)
        t.maxGasAmount_gasPriceCap = (uint256(_maxGasAmount) << 128) | uint256(_gasPriceCap);

        // Pack (uint128 | uint128)
        t.automationFeeCapForCycle_depositFee = (uint256(_automationFeeCapForCycle) << 128) | uint256(_depositFee);

        // Direct fields
        t.txHash = _txHash;
        t.payloadTx = _payloadTx;
        t.auxData = _auxData;

        // Pack (uint64 | uint64 | uint64 | uint64)
        // Layout: [taskIndex | registrationTime | expiryTime | priority]
        t.taskIndex_registrationTime_expiryTime_priority =
            (uint256(_taskIndex) << 192) |
            (uint256(_registrationTime) << 128) |
            (uint256(_expiryTime) << 64) |
            uint256(_priority);

        // Pack (address | uint8 | uint8)
        // Layout: [owner | taskType | taskState]
        t.owner_type_state =
            (uint256(uint160(_owner)) << 96) |
            (uint256(uint8(_type)) << 88) |
            (uint256(uint8(_state))<< 80);
    }

    // maxGasAmount (uint128) | gasPriceCap (uint128)
    function maxGasAmount(TaskMetadata storage t) internal view returns (uint128) {
        return uint128(t.maxGasAmount_gasPriceCap >> 128);
    }

    function gasPriceCap(TaskMetadata storage t) internal view returns (uint128) {
        return uint128(t.maxGasAmount_gasPriceCap);
    }

    function setMaxGasAmount(TaskMetadata storage t, uint128 _value) internal {
        t.maxGasAmount_gasPriceCap &= MAX_UINT128;              // clear upper 128
        t.maxGasAmount_gasPriceCap |= uint256(_value) << 128;   // insert upper 128
    }

    function setGasPriceCap(TaskMetadata storage t, uint128 _value) internal {
        t.maxGasAmount_gasPriceCap &= (MAX_UINT128 << 128);     // clear lower 128
        t.maxGasAmount_gasPriceCap |= uint256(_value);          // insert lower 128
    }

    // automationFeeCapForCycle (uint128) | depositFee (uint128)
    function automationFeeCapForCycle(TaskMetadata storage t) internal view returns (uint128) {
        return uint128(t.automationFeeCapForCycle_depositFee >> 128);
    }

    function depositFee(TaskMetadata storage t) internal view returns (uint128) {
        return uint128(t.automationFeeCapForCycle_depositFee);
    }

    function setAutomationFeeCapForCycle(TaskMetadata storage t, uint128 _value) internal {
        t.automationFeeCapForCycle_depositFee &= MAX_UINT128;
        t.automationFeeCapForCycle_depositFee |= uint256(_value) << 128;
    }

    function setDepositFee(TaskMetadata storage t, uint128 _value) internal {
        t.automationFeeCapForCycle_depositFee &= (MAX_UINT128 << 128);
        t.automationFeeCapForCycle_depositFee |= uint256(_value);
    }

    // taskIndex (uint64) | registrationTime (uint64) | expiryTime (uint64) | priority (uint64)
    function taskIndex(TaskMetadata storage t) internal view returns (uint64) {
        return uint64(t.taskIndex_registrationTime_expiryTime_priority >> 192);
    }

    function registrationTime(TaskMetadata storage t) internal view returns (uint64) {
        return uint64(t.taskIndex_registrationTime_expiryTime_priority >> 128);
    }

    function expiryTime(TaskMetadata storage t) internal view returns (uint64) {
        return uint64(t.taskIndex_registrationTime_expiryTime_priority >> 64);
    }

    function priority(TaskMetadata storage t) internal view returns (uint64) {
        return uint64(t.taskIndex_registrationTime_expiryTime_priority);
    }

    function setTaskIndex(TaskMetadata storage t, uint64 _value) internal {
        t.taskIndex_registrationTime_expiryTime_priority &= ~(MAX_UINT64 << 192);
        t.taskIndex_registrationTime_expiryTime_priority |= uint256(_value) << 192;
    }

    function setRegistrationTime(TaskMetadata storage t, uint64 _value) internal {
        t.taskIndex_registrationTime_expiryTime_priority &= ~(MAX_UINT64 << 128);
        t.taskIndex_registrationTime_expiryTime_priority |= uint256(_value) << 128;
    }

    function setExpiryTime(TaskMetadata storage t, uint64 _value) internal {
        t.taskIndex_registrationTime_expiryTime_priority &= ~(MAX_UINT64 << 64);
        t.taskIndex_registrationTime_expiryTime_priority |= uint256(_value) << 64;
    }

    function setPriority(TaskMetadata storage t, uint64 _value) internal {
        t.taskIndex_registrationTime_expiryTime_priority &= ~MAX_UINT64;
        t.taskIndex_registrationTime_expiryTime_priority |= uint256(_value);
    }

    // owner (address/uint160) | type (TaskType/uint8) | state (TaskState/uint8)
    function owner(TaskMetadata storage t) internal view returns (address) {
        return address(uint160(t.owner_type_state >> 96));
    }

    function taskType(TaskMetadata storage t) internal view returns (CommonUtils.TaskType) {
        return CommonUtils.TaskType(uint8(t.owner_type_state >> 88));
    }

    function state(TaskMetadata storage t) internal view returns (CommonUtils.TaskState) {
        return CommonUtils.TaskState(uint8(t.owner_type_state >> 80));
    }

    function setOwner(TaskMetadata storage t, address _value) internal {
        t.owner_type_state &= ~(MAX_UINT160 << 96);
        t.owner_type_state |= uint256(uint160(_value)) << 96;
    }

    function setType(TaskMetadata storage t, uint8 _value) internal {
        t.owner_type_state &= ~(MAX_UINT8 << 88);
        t.owner_type_state |= uint256(_value) << 88;
    }

    function setState(TaskMetadata storage t, uint8 _value) internal {
        t.owner_type_state &= ~(MAX_UINT8 << 80);
        t.owner_type_state |= uint256(_value) << 80;
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: RegistryState ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Tracks per-cycle automation state and task indexes.
    struct RegistryState {
        uint64 currentIndex;
        
        EnumerableSet.UintSet activeTaskIds;
        EnumerableSet.UintSet taskIdList;
        mapping(uint64 => TaskMetadata) tasks;   
        // mapping(address => uint64[]) userTasks       TO_DO: user to their tasks, need to decide on this 

        EnumerableSet.UintSet sysTaskIds;
        EnumerableSet.AddressSet authorizedAccounts;
    }

    /// @notice Struct representing a stopped task.
    struct TaskStopped {
        uint64 taskIndex;
        uint128 depositRefund;
        uint128 cycleFeeRefund;
        bytes32 txHash;
    }
}

