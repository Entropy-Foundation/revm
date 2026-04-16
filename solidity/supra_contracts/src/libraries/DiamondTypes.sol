// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

struct FacetsDeployment {
    address diamondCutFacet;
    address loupeFacet;
    address ownershipFacet;
    address configFacet;
    address registryFacet;
    address coreFacet;
    address diamondInit;
}

struct InitParams {
    uint64 taskDurationCapSecs;
    uint128 registryMaxGasCap;
    uint128 automationBaseFeeWeiPerSec;
    uint128 flatRegistrationFeeWei;
    uint8 congestionThresholdPercentage;
    uint128 congestionBaseFeeWeiPerSec;
    uint8 congestionExponent;
    uint16 taskCapacity;
    uint64 cycleDurationSecs;
    uint64 sysTaskDurationCapSecs;
    uint128 sysRegistryMaxGasCap;
    uint16 sysTaskCapacity;
    bool automationEnabled;
    bool registrationEnabled;
}
