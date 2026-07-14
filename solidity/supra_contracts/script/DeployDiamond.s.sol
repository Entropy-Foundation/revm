// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {Deployment, InitParams, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";

contract DeployDiamond is Script {
    address erc20Supra;
    address multiSig;

    InitParams initParams;

    // Config values loaded from .env file
    function setUp() public {
        initParams = InitParams({
            taskDurationCapSecs: uint64(vm.envUint("TASK_DURATION_CAP_SEC")),
            registryMaxGasCap: uint128(vm.envUint("REGISTRY_MAX_GAS_CAP")),
            automationBaseFeeWeiPerSec: uint128(vm.envUint("AUTOMATION_BASE_FEE_PER_SEC")),
            flatRegistrationFeeWei: uint128(vm.envUint("FLAT_REGISTRATION_FEE")),
            congestionThresholdPercentage: uint8(vm.envUint("CONGESTION_THRESHOLD_PERCENTAGE")),
            congestionBaseFeeWeiPerSec: uint128(vm.envUint("CONGESTION_BASE_FEE_PER_SEC")),
            congestionExponent: uint8(vm.envUint("CONGESTION_EXPONENT")),
            taskCapacity: uint16(vm.envUint("TASK_CAPACITY")),
            cycleDurationSecs: uint64(vm.envUint("CYCLE_DURATION_SEC")),
            sysTaskDurationCapSecs: uint64(vm.envUint("SYS_TASK_DURATION_CAP_SEC")),
            sysRegistryMaxGasCap: uint128(vm.envUint("SYS_REGISTRY_MAX_GAS_CAP")),
            sysTaskCapacity: uint16(vm.envUint("SYS_TASK_CAPACITY")),
            automationEnabled: vm.envBool("AUTOMATION_ENABLED"),
            registrationEnabled: vm.envBool("REGISTRATION_ENABLED")
        });

        erc20Supra = vm.envAddress("ERC20_SUPRA");
        multiSig = vm.envAddress("MULTI_SIG");
    }

    function run() external {
        vm.startBroadcast();

        // Deploy the Diamond, its facets and the DiamondInit and initialize the Diamond in a single transaction
        Deployment memory deployment = LibDiamondUtils.deploy(multiSig, erc20Supra, initParams);

        console.log("Diamond owner:", OwnershipFacet(address(deployment.diamond)).owner());
        console.log("Diamond deployed at:", address(deployment.diamond));
        console.log("DiamondCutFacet deployed at:", address(deployment.facets.diamondCutFacet));
        console.log("DiamondLoupeFacet deployed at:", address(deployment.facets.loupeFacet));
        console.log("OwnershipFacet deployed at:", address(deployment.facets.ownershipFacet));
        console.log("ConfigFacet deployed at:", address(deployment.facets.configFacet));
        console.log("RegistryFacet deployed at:", address(deployment.facets.registryFacet));
        console.log("CoreFacet deployed at:", address(deployment.facets.coreFacet));
        console.log("DiamondInit deployed at:", address(deployment.facets.diamondInit));

        vm.stopBroadcast();
    }
}