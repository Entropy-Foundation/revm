// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from"../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {AutomationRegistry} from "../src/AutomationRegistry.sol";
import {AutomationCore} from "../src/AutomationCore.sol";
import {AutomationController} from "../src/AutomationController.sol";
import {IAutomationController} from "../src/IAutomationController.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {CommonUtils} from "../src/CommonUtils.sol";

contract AutomationControllerTest is Test {
    ERC20Supra erc20Supra;                      // ERC20Supra contract
    AutomationCore automationCore;              // AutomationCore instance on proxy address
    AutomationRegistry registry;                // AutomationRegistry instance on proxy address
    AutomationController controller;            // AutomationController instance on proxy address

    address admin = address(0xA11CE);
    address vmSigner = address(0x53555000);
    address alice = address(0x123);
    address bob = address(0x456);

    /// @dev Sets up initial state for testing.
    /// @dev Sets balance of 'alice' to 100 ether.
    /// @dev Deploys and initializes all contracts with required parameters. 
    function setUp() public {
        vm.deal(alice, 100 ether);

        vm.startPrank(admin);
        erc20Supra = new ERC20Supra(msg.sender);

        AutomationCore automationCoreImpl = new AutomationCore();
        bytes memory automationCoreInitData = abi.encodeCall(
            AutomationCore.initialize,
            (
                3600,                       // taskDurationCapSecs
                10_000_000,                 // registryMaxGasCap
                0.001 ether,                // automationBaseFeeWeiPerSec
                0.002 ether,                // flatRegistrationFeeWei
                50,                         // congestionThresholdPercentage
                0.002 ether,                // congestionBaseFeeWeiPerSec
                2,                          // congestionExponent
                500,                        // taskCapacity
                2000,                       // cycleDurationSecs
                3600,                       // sysTaskDurationCapSecs
                5_000_000,                  // sysRegistryMaxGasCap
                500,                        // sysTaskCapacity
                vmSigner,                   // VM Signer address
                address(erc20Supra)        // ERC20Supra address
            )
        );
        ERC1967Proxy automationCoreProxy = new ERC1967Proxy(address(automationCoreImpl), automationCoreInitData);
        automationCore = AutomationCore(address(automationCoreProxy));
        
        AutomationRegistry registryImpl = new AutomationRegistry();
        bytes memory registryInitData = abi.encodeCall(AutomationRegistry.initialize, (address(automationCore)));
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = AutomationRegistry(address(registryProxy));

        AutomationController controllerImpl = new AutomationController();
        bytes memory controllerInitData = abi.encodeCall(AutomationController.initialize,(address(automationCore), address(registry)));
        ERC1967Proxy controllerProxy = new ERC1967Proxy(address(controllerImpl), controllerInitData);
        controller = AutomationController(address(controllerProxy));

        vm.stopPrank();
    }

    /// @dev Test to ensure all state variables are initialized correctly.
    function testInitialize() public view {
        assertEq(controller.owner(), admin);
        assertEq(address(controller.automationCore()), address(automationCore));
        assertEq(address(controller.registry()), address(registry));

        (uint64 index, uint64 startTime, uint64 durationSecs, CommonUtils.CycleState state) = controller.getCycleInfo();
        assertEq(index, 1);
        assertEq(startTime, block.timestamp);
        assertEq(durationSecs, automationCore.cycleDurationSecs());
        assertEq(uint8(state), uint8(CommonUtils.CycleState.STARTED));
    }

    /// @dev Test to ensure initialize reverts if reinitialized.
    function testInitializeRevertsIfReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        
        vm.prank(admin);
        controller.initialize(address(automationCore), address(registry));
    }

    /// @dev Test to ensure initialize reverts if AutomationCore address is zero.
    function testInitializeRevertsIfAutomationCoreAddressZero() public {
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize, (address(0), address(registry)));

        vm.expectRevert(CommonUtils.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev Test to ensure initialize reverts if AutomationCore address is EOA.
    function testInitializeRevertsIfAutomationCoreEoa() public {
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize, (alice, address(registry)));

        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev Test to ensure initialize reverts if AutomationRegistry address is zero.
    function testInitializeRevertsIfRegistryZero() public {
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize, (address(automationCore), address(0)));

        vm.expectRevert(CommonUtils.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev Test to ensure initialize reverts if AutomationRegistry address is EOA.
    function testInitializeRevertsIfRegistryEoa() public {
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize, (address(automationCore), alice));

        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);
        new ERC1967Proxy(address(impl), initData);
    }
    
    /// @dev Test to ensure 'setAutomationRegistry' reverts if caller is not owner.
    function testSetAutomationRegistryRevertsIfNotOwner() public {
        AutomationRegistry registryImplementation = new AutomationRegistry();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        controller.setAutomationRegistry(address(registryImplementation));
    }
    
    /// @dev Test to ensure 'setAutomationRegistry' reverts if address is zero.
    function testSetAutomationRegistryRevertsIfAddressZero() public {
        vm.expectRevert(CommonUtils.AddressCannotBeZero.selector);

        vm.prank(admin);
        controller.setAutomationRegistry(address(0));
    }

    /// @dev Test to ensure 'setAutomationRegistry' reverts if address is EOA.
    function testSetAutomationRegistryRevertsIfAddressEoa() public {
        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);

        vm.prank(admin);
        controller.setAutomationRegistry(alice);
    }

    /// @dev Test to ensure 'setAutomationRegistry' updates the registry address.
    function testSetAutomationRegistry() public {
        AutomationRegistry registryImplementation = new AutomationRegistry();

        vm.prank(admin);
        controller.setAutomationRegistry(address(registryImplementation));

        assertEq(address(controller.registry()), address(registryImplementation));
    }

    /// @dev Test to ensure 'setAutomationRegistry' emits event 'AutomationRegistryUpdated'.
    function testSetAutomationRegistryEmitsEvent() public {
        AutomationRegistry registryImplementation = new AutomationRegistry();

        vm.expectEmit(true, true, false, false);
        emit AutomationController.AutomationRegistryUpdated(address(controller.registry()), address(registryImplementation));

        vm.prank(admin);
        controller.setAutomationRegistry(address(registryImplementation));
    }

    /// @dev Test to ensure 'processTasks' reverts if caller is not VM Signer.
    function testProcessTasksRevertsIfNotVm() public {
        uint64[] memory tasks = new uint64[](1);
        tasks[0] = 0;

        vm.expectRevert(IAutomationController.CallerNotVmSigner.selector);

        vm.prank(admin);
        controller.processTasks(1, tasks);
    }
}