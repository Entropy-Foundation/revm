// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {CommonUtils} from "./CommonUtils.sol";

// Helper library used by AutomationConfig.
library LibConfig {
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
        // uint64 | uint64 | uint64 | CycleState(uint8)
        uint256 index_startTime_durationSecs_state;
        // uint128 | uint128
        uint256 gasCommittedForNextCycle_gasCommittedForThisCycle;
        // uint128 | uint128
        uint256 sysGasCommittedForNextCycle_sysGasCommittedForThisCycle;

        // uint128 | uint128
        uint256 nextCycleRegistryMaxGasCap_nextCycleSysRegistryMaxGasCap;
        // address | bool(1 bit)
        uint256 controller_registrationEnabled;
        uint256 cycleLockedFees;
        uint256 totalDepositedAutomationFees;
        address vmSigner;
        address erc20Supra;
        address registry;
        Config config;
    }
    
    function createRegistryConfig(
        uint64 _index,
        uint64 _startTime,
        uint64 _durationSecs,
        CommonUtils.CycleState _cycleState,
        uint128 _nextCycleRegistryMaxGasCap,
        uint128 _nextCycleSysRegistryMaxGasCap,
        bool _registrationEnabled,
        address _vmSigner,
        address _erc20Supra,
        Config memory _config
    ) internal pure returns (RegistryConfig memory rcfg) {
        // Pack index(uint64) | startTime(uint64) | durationSecs(uint64) | cycleState(uint8)
        rcfg.index_startTime_durationSecs_state = 
            (uint256(_index) << 192) |
            (uint256(_startTime) << 128) |
            (uint256(_durationSecs) << 64) |
            (uint256(uint8(_cycleState)) << 56);

        // Pack nextCycleRegistryMaxGasCap | nextCycleSysRegistryMaxGasCap
        rcfg.nextCycleRegistryMaxGasCap_nextCycleSysRegistryMaxGasCap =
            (uint256(_nextCycleRegistryMaxGasCap) << 128) |
            uint256(_nextCycleSysRegistryMaxGasCap);

        // Pack controller (address) | registrationEnabled (bool at bit 95)
        // Sets controller as address(0)
        rcfg.controller_registrationEnabled = _registrationEnabled ? uint256(1) << 95 : 0;

        rcfg.vmSigner = _vmSigner;
        rcfg.erc20Supra = _erc20Supra;
        
        // Assign inner Config
        rcfg.config = _config;
    }

    // index(uint64) | startTime(uint64) | durationSecs(uint64) | state(CycleState/uint8)
    function index(RegistryConfig storage r) internal view returns (uint64) {
        return uint64(r.index_startTime_durationSecs_state >> 192);
    }

    function startTime(RegistryConfig storage r) internal view returns (uint64) {
        return uint64(r.index_startTime_durationSecs_state >> 128);
    }

    function durationSecs(RegistryConfig storage r) internal view returns (uint64) {
        return uint64(r.index_startTime_durationSecs_state >> 64);
    }

    function state(RegistryConfig storage r) internal view returns (CommonUtils.CycleState) {
        return CommonUtils.CycleState(uint8(r.index_startTime_durationSecs_state >> 56));
    }

    function setIndex(RegistryConfig storage r, uint64 _index) internal {
        r.index_startTime_durationSecs_state &= ~(MAX_UINT64 << 192);     // Clear old bits
        r.index_startTime_durationSecs_state |= uint256(_index) << 192;   // Set new value
    }

    function setStartTime(RegistryConfig storage r, uint64 _startTime) internal {
        r.index_startTime_durationSecs_state &= ~(MAX_UINT64 << 128);
        r.index_startTime_durationSecs_state |= uint256(_startTime) << 128;
    }

    function setDurationSecs(RegistryConfig storage r, uint64 _durationSecs) internal {
        r.index_startTime_durationSecs_state &= ~(MAX_UINT64 << 64);
        r.index_startTime_durationSecs_state |= uint256(_durationSecs) << 64;
    }

    function setState(RegistryConfig storage r, uint8 _state) internal {
        r.index_startTime_durationSecs_state &= ~(MAX_UINT8 << 56);
        r.index_startTime_durationSecs_state |= uint256(_state) << 56;
    }

    // gasCommittedForNextCycle (uint128) | gasCommittedForThisCycle (uint128)
    function gasCommittedForNextCycle(RegistryConfig storage r) internal view returns (uint128) {
        return uint128(r.gasCommittedForNextCycle_gasCommittedForThisCycle >> 128);
    }

    function gasCommittedForThisCycle(RegistryConfig storage r) internal view returns (uint128) {
        return uint128(r.gasCommittedForNextCycle_gasCommittedForThisCycle);
    }

    function setGasCommittedForNextCycle(RegistryConfig storage r, uint128 _value) internal {
        // Clear upper 128 bits
        r.gasCommittedForNextCycle_gasCommittedForThisCycle &= MAX_UINT128; 
        // Insert new upper 128 bits
        r.gasCommittedForNextCycle_gasCommittedForThisCycle |= uint256(_value) << 128;
    }

    function setGasCommittedForThisCycle(RegistryConfig storage r, uint128 _value) internal {
        // Clear lower 128 bits
        r.gasCommittedForNextCycle_gasCommittedForThisCycle &= MAX_UINT128 << 128;
        // Insert new lower 128 bits
        r.gasCommittedForNextCycle_gasCommittedForThisCycle |= uint256(_value);
    }

    // sysGasCommittedForNextCycle (uint128) | sysGasCommittedForThisCycle (uint128)
    function sysGasCommittedForNextCycle(RegistryConfig storage r) internal view returns (uint128){
        return uint128(r.sysGasCommittedForNextCycle_sysGasCommittedForThisCycle >> 128);
    }

    function sysGasCommittedForThisCycle(RegistryConfig storage r) internal view returns (uint128){
        return uint128(r.sysGasCommittedForNextCycle_sysGasCommittedForThisCycle);
    }

    function setSysGasCommittedForNextCycle(RegistryConfig storage r, uint128 _value) internal {
        // Clear upper 128 bits
        r.sysGasCommittedForNextCycle_sysGasCommittedForThisCycle &= MAX_UINT128; // mask = lower 128 bits all 1s

        // Insert new upper 128 bits
        r.sysGasCommittedForNextCycle_sysGasCommittedForThisCycle |= uint256(_value) << 128;
    }

    function setSysGasCommittedForThisCycle(RegistryConfig storage r, uint128 _value) internal {
        // Clear lower 128 bits
        r.sysGasCommittedForNextCycle_sysGasCommittedForThisCycle &= MAX_UINT128 << 128; // mask = upper 128 bits all 1s

        // Insert new lower 128 bits
        r.sysGasCommittedForNextCycle_sysGasCommittedForThisCycle |= uint256(_value);
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

    // controller (address) | registrationEnabled (bool)[bit 95]
    function automationController(RegistryConfig storage r) internal view returns (address) {
        return address(uint160(r.controller_registrationEnabled >> 96));
    }

    function registrationEnabled(RegistryConfig storage r) internal view returns (bool) {
        return (r.controller_registrationEnabled >> 95) & 1 != 0;
    }

    function setAutomationController(RegistryConfig storage r, address _controller) internal {
        // clear top 160 bits
        r.controller_registrationEnabled &= ~(MAX_UINT160 << 96);

        // insert 160-bit address
        r.controller_registrationEnabled |= uint256(uint160(_controller)) << 96;
    }

    function setRegistrationEnabled(RegistryConfig storage r, bool enabled) internal {
        // clear bit 95
        r.controller_registrationEnabled &= ~(uint256(1) << 95);

        // set bit 95 if enabled
        r.controller_registrationEnabled |= enabled ? (uint256(1) << 95) : 0;
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