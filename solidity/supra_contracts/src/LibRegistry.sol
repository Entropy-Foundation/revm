
// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {EnumerableSet} from "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {CommonUtils} from "./CommonUtils.sol";

// Helper library used by AutomationRegistry.
library LibRegistry {
    
    uint256 private constant MAX_UINT128 = type(uint128).max;
    uint256 private constant MAX_UINT160 = type(uint160).max;
    uint256 private constant MAX_UINT64 = type(uint64).max;
    uint256 private constant MAX_UINT16 = type(uint16).max;
    uint256 private constant MAX_UINT8 = type(uint8).max;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: AccessListEntry :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Struct representing an entry in access list.
    struct AccessListEntry {
        address addr;
        bytes32[] storageKeys;
    }
    
    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ConfigBuffer :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Struct representing configuration buffer.
    struct ConfigBuffer {
        Config pendingConfig;             
        bool ifExists;
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: RegistryConfig :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Configuration of the automation registry.
    struct RegistryConfig {
        // uint128 | uint128
        uint256 nextCycleRegistryMaxGasCap_nextCycleSysRegistryMaxGasCap;
        // address | bool | bool
        uint256 controller_registrationEnabled_automationEnabled;
        address vmSigner;
        address erc20Supra;
        Config config;
    }
    
    function createRegistryConfig(
        uint128 _nextCycleRegistryMaxGasCap,
        uint128 _nextCycleSysRegistryMaxGasCap,
        bool _registrationEnabled,
        bool _automationEnabled,
        address _vmSigner,
        address _erc20Supra,
        Config memory _config
    ) internal pure returns (RegistryConfig memory rcfg) {
        // Pack nextCycleRegistryMaxGasCap | nextCycleSysRegistryMaxGasCap
        rcfg.nextCycleRegistryMaxGasCap_nextCycleSysRegistryMaxGasCap =
            (uint256(_nextCycleRegistryMaxGasCap) << 128) |
            uint256(_nextCycleSysRegistryMaxGasCap);

        // Pack controller (address) | registrationEnabled (bool at bit 95) | automationEnabled (bool at bit 94)
        // Sets controller as address(0)
        rcfg.controller_registrationEnabled_automationEnabled = 
            (_registrationEnabled ? (uint256(1) << 95) : 0) |
            (_automationEnabled ? (uint256(1) << 94) : 0);

        rcfg.vmSigner = _vmSigner;
        rcfg.erc20Supra = _erc20Supra;
        
        // Assign inner Config
        rcfg.config = _config;
    }

    // nextCycleRegistryMaxGasCap (uint128) | nextCycleSysRegistryMaxGasCap (uint128)
    function nextCycleRegistryMaxGasCap(RegistryConfig storage r) internal view returns (uint128) {
        return uint128(r.nextCycleRegistryMaxGasCap_nextCycleSysRegistryMaxGasCap >> 128);
    }

    function nextCycleSysRegistryMaxGasCap(RegistryConfig storage r) internal view returns (uint128) {
        return uint128(r.nextCycleRegistryMaxGasCap_nextCycleSysRegistryMaxGasCap);
    }

    function setNextCycleRegistryMaxGasCap(RegistryConfig storage r, uint128 value) internal {
        // clear upper 128 bits then set
        r.nextCycleRegistryMaxGasCap_nextCycleSysRegistryMaxGasCap &= MAX_UINT128;
        r.nextCycleRegistryMaxGasCap_nextCycleSysRegistryMaxGasCap |= uint256(value) << 128;
    }

    function setNextCycleSysRegistryMaxGasCap(RegistryConfig storage r, uint128 value) internal {
        // clear lower 128 bits then set
        r.nextCycleRegistryMaxGasCap_nextCycleSysRegistryMaxGasCap &= (MAX_UINT128 << 128);
        r.nextCycleRegistryMaxGasCap_nextCycleSysRegistryMaxGasCap |= uint256(value);
    }

    // controller (address) | registrationEnabled (bool) [stored at bit 95] | automationEnabled (bool) [stored at bit 94]
    function automationController(RegistryConfig storage r) internal view returns (address) {
        return address(uint160(r.controller_registrationEnabled_automationEnabled >> 96));
    }

    function registrationEnabled(RegistryConfig storage r) internal view returns (bool) {
        return (r.controller_registrationEnabled_automationEnabled >> 95) & 1 != 0;
    }

    function automationEnabled(RegistryConfig storage r) internal view returns (bool) {
        return (r.controller_registrationEnabled_automationEnabled >> 94) & 1 != 0;
    }

    function setAutomationController(RegistryConfig storage r, address _controller) internal {
        // clear top 160 bits
        r.controller_registrationEnabled_automationEnabled &= ~(MAX_UINT160 << 96);

        // insert 160-bit address
        r.controller_registrationEnabled_automationEnabled |= uint256(uint160(_controller)) << 96;
    }

    function setRegistrationEnabled(RegistryConfig storage r, bool enabled) internal {
        // clear bit 95
        r.controller_registrationEnabled_automationEnabled &= ~(uint256(1) << 95);

        // set bit 95 if enabled
        r.controller_registrationEnabled_automationEnabled |= enabled ? (uint256(1) << 95) : 0;
    }

    function setAutomationEnabled(RegistryConfig storage r, bool enabled) internal {
        // clear bit 94
        r.controller_registrationEnabled_automationEnabled &= ~(uint256(1) << 94);

        // set bit 94 if enabled
        r.controller_registrationEnabled_automationEnabled |= enabled ? (uint256(1) << 94) : 0;
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Config :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @notice Struct representing configuration parameters.
    struct Config {
        // uint128 | uint128
        uint256 registryMaxGasCap_sysRegistryMaxGasCap;
        // uint128 | uint128  // TO_DO: need to decide on the currency
        uint256 automationBaseFeeWeiPerSec_flatRegistrationFeeWei;        
        // uint128 | uint64 | uint64  // TO_DO: need to decide on the currency
        uint256 congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs;
        // uint64 | uint16 | uint16 | uint8 | uint8
        uint256 cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent;
    }

    function createConfig(
        uint128 _registryMaxGasCap,
        uint128 _sysRegistryMaxGasCap,
        uint128 _automationBaseFeeWeiPerSec,
        uint128 _flatRegistrationFeeWei,
        uint128 _congestionBaseFeeWeiPerSec,
        uint64 _taskDurationCapSecs,
        uint64 _sysTaskDurationCapSecs,
        uint64 _cycleDurationSecs,
        uint16 _taskCapacity,
        uint16 _sysTaskCapacity,
        uint8 _congestionThresholdPercentage,
        uint8 _congestionExponent
    ) internal pure returns (Config memory cfg) {
        // Pack registryMaxGasCap | sysRegistryMaxGasCap
        cfg.registryMaxGasCap_sysRegistryMaxGasCap = (uint256(_registryMaxGasCap) << 128) | uint256(_sysRegistryMaxGasCap);

        // Pack automationBaseFeeWeiPerSec | flatRegistrationFeeWei
        cfg.automationBaseFeeWeiPerSec_flatRegistrationFeeWei = (uint256(_automationBaseFeeWeiPerSec) << 128) | uint256(_flatRegistrationFeeWei);

        // Pack congestionBaseFeeWeiPerSec | taskDurationCapSecs | sysTaskDurationCapSecs
        cfg.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs =
            (uint256(_congestionBaseFeeWeiPerSec) << 128) |
            (uint256(_taskDurationCapSecs) << 64) |
            uint256(_sysTaskDurationCapSecs);

        // Pack cycleDurationSecs | taskCapacity | sysTaskCapacity | congestionThresholdPercentage | congestionExponent
        cfg.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent =
            (uint256(_cycleDurationSecs) << 192) |
            (uint256(_taskCapacity) << 176) |
            (uint256(_sysTaskCapacity) << 160) |
            (uint256(_congestionThresholdPercentage) << 152) |
            (uint256(_congestionExponent) << 144);
    }

    // uint256 registryMaxGasCap (uint128) | sysRegistryMaxGasCap (uint128)
    function registryMaxGasCap(RegistryConfig storage r) internal view returns (uint128) {
        return uint128(r.config.registryMaxGasCap_sysRegistryMaxGasCap >> 128);
    }

    function sysRegistryMaxGasCap(RegistryConfig storage r) internal view returns (uint128) {
        return uint128(r.config.registryMaxGasCap_sysRegistryMaxGasCap);
    }

    function setRegistryMaxGasCap(RegistryConfig storage r, uint128 value) internal {
        r.config.registryMaxGasCap_sysRegistryMaxGasCap &= MAX_UINT128;
        r.config.registryMaxGasCap_sysRegistryMaxGasCap |= uint256(value) << 128;
    }

    function setSysRegistryMaxGasCap(RegistryConfig storage r, uint128 value) internal {
        r.config.registryMaxGasCap_sysRegistryMaxGasCap &= (MAX_UINT128 << 128);
        r.config.registryMaxGasCap_sysRegistryMaxGasCap |= uint256(value);
    }

    // automationBaseFeeWeiPerSec (uint128) | flatRegistrationFeeWei (uint128)  
    function automationBaseFeeWeiPerSec(RegistryConfig storage r) internal view returns (uint128) {
        return uint128(r.config.automationBaseFeeWeiPerSec_flatRegistrationFeeWei >> 128);
    }

    function flatRegistrationFeeWei(RegistryConfig storage r) internal view returns (uint128) {
        return uint128(r.config.automationBaseFeeWeiPerSec_flatRegistrationFeeWei);
    }

    function setAutomationBaseFeeWeiPerSec(RegistryConfig storage r, uint128 value) internal {
        r.config.automationBaseFeeWeiPerSec_flatRegistrationFeeWei &= MAX_UINT128;
        r.config.automationBaseFeeWeiPerSec_flatRegistrationFeeWei |= uint256(value) << 128;
    }

    function setFlatRegistrationFeeWei(RegistryConfig storage r, uint128 value) internal {
        r.config.automationBaseFeeWeiPerSec_flatRegistrationFeeWei &= (MAX_UINT128 << 128);
        r.config.automationBaseFeeWeiPerSec_flatRegistrationFeeWei |= uint256(value);
    }

    // congestionBaseFeeWeiPerSec (uint128) | taskDurationCapSecs (uint64) | sysTaskDurationCapSecs (uint64)
    function congestionBaseFeeWeiPerSec(RegistryConfig storage r) internal view returns (uint128) {
        return uint128(r.config.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs >> 128);
    }

    function taskDurationCapSecs(RegistryConfig storage r) internal view returns (uint64) {
        return uint64(r.config.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs >> 64);
    }

    function sysTaskDurationCapSecs(RegistryConfig storage r) internal view returns (uint64) {
        return uint64(r.config.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs);
    }

    function setCongestionBaseFeeWeiPerSec(RegistryConfig storage r, uint128 _value) internal {
        r.config.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs &= MAX_UINT128;
        r.config.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs |= uint256(_value) << 128;
    }

    function setTaskDurationCapSecs(RegistryConfig storage r, uint64 value) internal {
        r.config.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs &= ~(MAX_UINT64 << 64); 
        r.config.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs |= uint256(value) << 64;
    }

    function setSysTaskDurationCapSecs(RegistryConfig storage r, uint64 value) internal {
        r.config.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs &= ~MAX_UINT64; 
        r.config.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs |= uint256(value);
    }

    // cycleDurationSecs (uint64) | taskCapacity (uint16) | sysTaskCapacity (uint16) | congestionThresholdPercentage (uint8) | congestionExponent (uint8)
    function cycleDurationSecs(Config storage c) internal view returns (uint64) {
        return uint64(c.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent >> 192);
    }

    function taskCapacity(RegistryConfig storage r) internal view returns (uint16) {
        return uint16(r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent >> 176);
    }

    function sysTaskCapacity(RegistryConfig storage r) internal view returns (uint16) {
        return uint16(r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent >> 160);
    }

    function congestionThresholdPercentage(RegistryConfig storage r) internal view returns (uint8) {
        return uint8(r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent >> 152);
    }

    function congestionExponent(RegistryConfig storage r) internal view returns (uint8) {
        return uint8(r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent >> 144);
    }

    function setCycleDurationSecs(RegistryConfig storage r, uint64 _value) internal {
        r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent &= ~(MAX_UINT64 << 192); 
        r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent |= uint256(_value) << 192;
    }

    function setTaskCapacity(RegistryConfig storage r, uint16 _value) internal {
        r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent &= ~(MAX_UINT16 << 176); 
        r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent |= uint256(_value) << 176;
    }

    function setSysTaskCapacity(RegistryConfig storage r, uint16 _value) internal {
        r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent &= ~(MAX_UINT16 << 160); 
        r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent |= uint256(_value) << 160;
    }

    function setCongestionThresholdPercentage(RegistryConfig storage r, uint8 _value) internal {
        r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent &= ~(MAX_UINT8 << 152);
        r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent |= uint256(_value) << 152;
    }

    function setCongestionExponent(RegistryConfig storage r, uint8 _value) internal {
        r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent &= ~(MAX_UINT8 << 144);
        r.config.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent |= uint256(_value) << 144;
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: TaskMetadata ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Task metadata for individual automation tasks.
    struct TaskMetadata {
        // uint128 | uint128
        uint256 maxGasAmount_gasPriceCap;
        
        // uint128 | uint128
        uint256 automationFeeCapForCycle_lockedFeeForNextCycle;

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
        uint128 _lockedFeeForNextCycle,
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
        t.automationFeeCapForCycle_lockedFeeForNextCycle = (uint256(_automationFeeCapForCycle) << 128) | uint256(_lockedFeeForNextCycle);

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

    // automationFeeCapForCycle (uint128) | lockedFeeForNextCycle (uint128)
    function automationFeeCapForCycle(TaskMetadata storage t) internal view returns (uint128) {
        return uint128(t.automationFeeCapForCycle_lockedFeeForNextCycle >> 128);
    }

    function lockedFeeForNextCycle(TaskMetadata storage t) internal view returns (uint128) {
        return uint128(t.automationFeeCapForCycle_lockedFeeForNextCycle);
    }

    function setAutomationFeeCapForCycle(TaskMetadata storage t, uint128 _value) internal {
        t.automationFeeCapForCycle_lockedFeeForNextCycle &= MAX_UINT128;
        t.automationFeeCapForCycle_lockedFeeForNextCycle |= uint256(_value) << 128;
    }

    function setLockedFeeForNextCycle(TaskMetadata storage t, uint128 _value) internal {
        t.automationFeeCapForCycle_lockedFeeForNextCycle &= (MAX_UINT128 << 128);
        t.automationFeeCapForCycle_lockedFeeForNextCycle |= uint256(_value);
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
        uint256 cycleLockedFees;
        
        // uint128 | uint128
        uint256 gasCommittedForNextCycle_gasCommittedForThisCycle;
        
        uint64 currentIndex;
        
        EnumerableSet.UintSet activeTaskIds;
        EnumerableSet.UintSet taskIdList;
        mapping(uint64 => TaskMetadata) tasks;   
        // mapping(address => uint64[]) userTasks       TO_DO: user to their tasks, need to decide on this 
    }

    // gasCommittedForNextCycle (uint128) | gasCommittedForThisCycle (uint128)
    function gasCommittedForNextCycle(RegistryState storage r) internal view returns (uint128) {
        return uint128(r.gasCommittedForNextCycle_gasCommittedForThisCycle >> 128);
    }

    function gasCommittedForThisCycle(RegistryState storage r) internal view returns (uint128) {
        return uint128(r.gasCommittedForNextCycle_gasCommittedForThisCycle);
    }

    function setGasCommittedForNextCycle(RegistryState storage r, uint128 _value) internal {
        // Clear upper 128 bits
        r.gasCommittedForNextCycle_gasCommittedForThisCycle &= MAX_UINT128; 
        // Insert new upper 128 bits
        r.gasCommittedForNextCycle_gasCommittedForThisCycle |= uint256(_value) << 128;
    }

    function setGasCommittedForThisCycle(RegistryState storage r, uint128 _value) internal {
        // Clear lower 128 bits
        r.gasCommittedForNextCycle_gasCommittedForThisCycle &= MAX_UINT128 << 128;
        // Insert new lower 128 bits
        r.gasCommittedForNextCycle_gasCommittedForThisCycle |= uint256(_value);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: RegistryStateSystemTasks :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Tracks per-cycle automation state and task indexes for system tasks.
    struct RegistryStateSystemTasks {
        // uint128 | uint128
        uint256 gasCommittedForNextCycle_gasCommittedForThisCycle;
        
        EnumerableSet.UintSet taskIds;
        EnumerableSet.AddressSet authorizedAccounts;
    }

    // gasCommittedForNextCycle (uint128) | gasCommittedForThisCycle (uint128)
    function gasCommittedForNextCycle(RegistryStateSystemTasks storage s) internal view returns (uint128){
        return uint128(s.gasCommittedForNextCycle_gasCommittedForThisCycle >> 128);
    }

    function gasCommittedForThisCycle(RegistryStateSystemTasks storage s) internal view returns (uint128){
        return uint128(s.gasCommittedForNextCycle_gasCommittedForThisCycle);
    }

    function setGasCommittedForNextCycle(RegistryStateSystemTasks storage s, uint128 _value) internal {
        // Clear upper 128 bits
        s.gasCommittedForNextCycle_gasCommittedForThisCycle &= MAX_UINT128; // mask = lower 128 bits all 1s

        // Insert new upper 128 bits
        s.gasCommittedForNextCycle_gasCommittedForThisCycle |= uint256(_value) << 128;
    }

    function setGasCommittedForThisCycle(RegistryStateSystemTasks storage s, uint128 _value) internal {
        // Clear lower 128 bits
        s.gasCommittedForNextCycle_gasCommittedForThisCycle &= MAX_UINT128 << 128; // mask = upper 128 bits all 1s

        // Insert new lower 128 bits
        s.gasCommittedForNextCycle_gasCommittedForThisCycle |= uint256(_value);
    }

    /// @notice Deposit and fee related accounting.
    struct Deposit {
        uint256 totalDepositedAutomationFees;
        address coldWallet;
    }

    /// @notice Struct representing a stopped task.
    struct TaskStopped {
        uint64 taskIndex;
        uint128 depositRefund;
        uint128 cycleFeeRefund;
        bytes32 txHash;
    }

    /// @notice Struct representing configuration details.
    struct ConfigDetails {
        uint128 registryMaxGasCap;
        uint128 sysRegistryMaxGasCap;
        uint128 automationBaseFeeWeiPerSec;  // TO_DO: need to decide on the currency
        uint128 flatRegistrationFeeWei;      // TO_DO: need to decide on the currency
        uint128 congestionBaseFeeWeiPerSec;  // TO_DO: need to decide on the currency
        uint64 taskDurationCapSecs;
        uint64 sysTaskDurationCapSecs;
        uint64 cycleDurationSecs;
        uint16 taskCapacity;
        uint16 sysTaskCapacity;
        uint8 congestionThresholdPercentage;
        uint8 congestionExponent;
    }

    function getConfig(Config memory cfg) internal pure returns (ConfigDetails memory config) {
        // -------------------------------------------------------------
        // 1. registryMaxGasCap (high 128) | sysRegistryMaxGasCap (low 128)
        // -------------------------------------------------------------
        config.registryMaxGasCap       = uint128(cfg.registryMaxGasCap_sysRegistryMaxGasCap >> 128);
        config.sysRegistryMaxGasCap    = uint128(cfg.registryMaxGasCap_sysRegistryMaxGasCap);

        // -------------------------------------------------------------
        // 2. automationBaseFeeWeiPerSec (high 128) | flatRegistrationFeeWei (low 128)
        // -------------------------------------------------------------
        config.automationBaseFeeWeiPerSec = uint128(cfg.automationBaseFeeWeiPerSec_flatRegistrationFeeWei >> 128);
        config.flatRegistrationFeeWei     = uint128(cfg.automationBaseFeeWeiPerSec_flatRegistrationFeeWei);

        // -------------------------------------------------------------
        // 3. congestionBaseFeeWeiPerSec (high 128)
        //    taskDurationCapSecs (next 64)
        //    sysTaskDurationCapSecs (low 64)
        // -------------------------------------------------------------
        config.congestionBaseFeeWeiPerSec = uint128(cfg.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs >> 128);
        config.taskDurationCapSecs        = uint64(cfg.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs >> 64);
        config.sysTaskDurationCapSecs     = uint64(cfg.congestionBaseFeeWeiPerSec_taskDurationCapSecs_sysTaskDurationCapSecs);

        // -------------------------------------------------------------
        // 4. cycleDurationSecs (high 64)
        //    taskCapacity (next 16)
        //    sysTaskCapacity (next 16)
        //    congestionThresholdPercentage (next 8)
        //    congestionExponent (low 8)
        // -------------------------------------------------------------
        config.cycleDurationSecs              = uint64(cfg.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent >> 192);
        config.taskCapacity                   = uint16(cfg.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent >> 176);
        config.sysTaskCapacity                = uint16(cfg.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent >> 160);
        config.congestionThresholdPercentage  = uint8(cfg.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent >> 152);
        config.congestionExponent             = uint8(cfg.cycleDurationSecs_taskCapacity_sysTaskCapacity_congestionThresholdPercentage_congestionExponent >> 144);
    }
}

