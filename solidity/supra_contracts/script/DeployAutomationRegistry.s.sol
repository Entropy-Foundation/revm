// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {AutomationCore} from "../src/AutomationCore.sol";
import {AutomationController} from "../src/AutomationController.sol";
import {AutomationRegistry} from "../src/AutomationRegistry.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployAutomationRegistry is Script {
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
    address vmSigner;
    address erc20Supra;  
    bool automationEnabled;  

    // Config values loaded from .env file
    function setUp() public {
        taskDurationCapSecs = uint64(vm.envUint("TASK_DURATION_CAP_SEC"));
        registryMaxGasCap = uint128(vm.envUint("REGISTRY_MAX_GAS_CAP"));
        automationBaseFeeWeiPerSec = uint128(vm.envUint("AUTOMATION_BASE_FEE_PER_SEC"));
        flatRegistrationFeeWei = uint128(vm.envUint("FLAT_REGISTRATION_FEE"));
        congestionThresholdPercentage = uint8(vm.envUint("CONGESTION_THRESHOLD_PERCENTAGE"));
        congestionBaseFeeWeiPerSec = uint128(vm.envUint("CONGESTION_BASE_FEE_PER_SEC"));
        congestionExponent = uint8(vm.envUint("CONGESTION_EXPONENT"));
        taskCapacity = uint16(vm.envUint("TASK_CAPACITY"));
        cycleDurationSecs = uint64(vm.envUint("CYCLE_DURATION_SEC"));
        sysTaskDurationCapSecs = uint64(vm.envUint("SYS_TASK_DURATION_CAP_SEC"));
        sysRegistryMaxGasCap = uint128(vm.envUint("SYS_REGISTRY_MAX_GAS_CAP"));
        sysTaskCapacity = uint16(vm.envUint("SYS_TASK_CAPACITY"));
        vmSigner = vm.envAddress("VM_SIGNER");
        erc20Supra = vm.envAddress("ERC20_SUPRA");
        automationEnabled = true;
    }

    function run() public {
        vm.startBroadcast();

        AutomationCore coreImpl;                        // AutomationCore implementation contract
        ERC1967Proxy coreProxy;                         // AutomationCore proxy contract
        AutomationCore automationCore;                  // Instance of AutomationCore at proxy address

        AutomationRegistry registryImpl;                // AutomationRegistry implementation contract
        ERC1967Proxy registryProxy;                     // AutomationRegistry proxy contract
        AutomationRegistry registry;                    // Instance of AutomationRegistry at proxy address

        AutomationController controllerImpl;            // AutomationController implementation contract           
        ERC1967Proxy controllerProxy;                   // AutomationController proxy contract
        AutomationController controller;                // Instance of AutomationController at proxy address

        // ---------------------------------------------------------------------
        // Deploy AutomationCore
        // ---------------------------------------------------------------------
        coreImpl = new AutomationCore();
        console.log("AutomationCore implementation deployed at: ", address(coreImpl));
        bytes memory coreInitData = abi.encodeCall(
            AutomationCore.initialize,
            (
                taskDurationCapSecs,                    // taskDurationCapSecs
                registryMaxGasCap,                      // registryMaxGasCap
                automationBaseFeeWeiPerSec,             // automationBaseFeeWeiPerSec
                flatRegistrationFeeWei,                 // flatRegistrationFeeWei
                congestionThresholdPercentage,          // congestionThresholdPercentage
                congestionBaseFeeWeiPerSec,             // congestionBaseFeeWeiPerSec
                congestionExponent,                     // congestionExponent
                taskCapacity,                           // taskCapacity
                cycleDurationSecs,                      // cycleDurationSecs
                sysTaskDurationCapSecs,                 // sysTaskDurationCapSecs
                sysRegistryMaxGasCap,                   // sysRegistryMaxGasCap
                sysTaskCapacity,                        // sysTaskCapacity
                vmSigner,                               // VM Signer address
                erc20Supra,                             // ERC20Supra address
                automationEnabled                       // automationEnabled
            )
        );
        coreProxy = new ERC1967Proxy(address(coreImpl), coreInitData);
        console.log("AutomationCore proxy deployed at: ", address(coreProxy));
        automationCore = AutomationCore(address(coreProxy));

        // ---------------------------------------------------------------------
        // Deploy AutomationRegistry
        // ---------------------------------------------------------------------
        registryImpl = new AutomationRegistry();
        console.log("AutomationRegistry implementation deployed at: ", address(registryImpl));
        
        bytes memory registryInitData = abi.encodeCall(AutomationRegistry.initialize, (address(automationCore)));
        registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        console.log("AutomationRegistry proxy deployed at: ", address(registryProxy));
        registry = AutomationRegistry(address(registryProxy));

        // ---------------------------------------------------------------------
        // Deploy AutomationController
        // ---------------------------------------------------------------------
        controllerImpl = new AutomationController();
        console.log("AutomationController implementation deployed at: ", address(controllerImpl));
        
        bytes memory controllerInitData = abi.encodeCall(
            AutomationController.initialize,
            (
                address(automationCore),
                address(registry),
                true
            )
        );
        controllerProxy = new ERC1967Proxy(address(controllerImpl), controllerInitData);
        console.log("AutomationController proxy deployed at: ", address(controllerProxy));
        controller = AutomationController(address(controllerProxy));

        // --------------------------------------------------------------------------
        // Set AutomationRegistry and AutomationController address in AutomationCore
        // --------------------------------------------------------------------------
        automationCore.setAutomationRegistry(address(registry));
        automationCore.setAutomationController(address(controller));

        // --------------------------------------------------------------------------
        // Set AutomationController address in AutomationRegistry
        // --------------------------------------------------------------------------
        registry.setAutomationController(address(controller));

        vm.stopBroadcast();
    }
}
