// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {AutomationCore} from "../src/AutomationCore.sol";
import {AutomationController} from "../src/AutomationController.sol";
import {AutomationRegistry} from "../src/AutomationRegistry.sol";
import {IAutomationCore} from "../src/IAutomationCore.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {CommonUtils} from "../src/CommonUtils.sol";
import {LibConfig} from "../src/LibConfig.sol";

contract AutomationCoreTest is Test {
    ERC20Supra erc20Supra;                      // ERC20Supra contract
    AutomationCore automationCore;              // AutomationCore instance on proxy address
    AutomationRegistry registry;                // AutomationRegistry instance on proxy address
    address automationController;               // AutomationController proxy address

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
                address(erc20Supra)         // ERC20Supra address
            )
        );
        ERC1967Proxy automationCoreProxy = new ERC1967Proxy(address(automationCoreImpl), automationCoreInitData);
        automationCore = AutomationCore(address(automationCoreProxy));

        AutomationRegistry registryImpl = new AutomationRegistry();
        bytes memory registryInitData = abi.encodeCall(AutomationRegistry.initialize, (address(automationCore)));
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = AutomationRegistry(address(registryProxy));
        automationCore.setAutomationRegistry(address(registry));

        AutomationController controllerImpl = new AutomationController();
        bytes memory controllerInitData = abi.encodeCall(AutomationController.initialize,(address(automationCore), address(registry)));
        ERC1967Proxy controllerProxy = new ERC1967Proxy(address(controllerImpl), controllerInitData);
        automationController = address(controllerProxy);
        automationCore.setAutomationController(automationController);

        vm.stopPrank();
    }

    /// @dev Test to ensure all state variables are initialized correctly.
    function testInitialize() public view {
        assertEq(automationCore.owner(), admin);
        assertEq(automationCore.getNextCycleRegistryMaxGasCap(), 10_000_000);
        assertEq(automationCore.getNextCycleSysRegistryMaxGasCap(), 5_000_000);
        assertEq(automationCore.getAutomationController(), automationController);
        assertTrue(automationCore.isRegistrationEnabled());
        assertTrue(automationCore.isAutomationEnabled());
        assertEq(automationCore.getVmSigner(), vmSigner);
        assertEq(automationCore.erc20Supra(), address(erc20Supra));

        LibConfig.ConfigDetails memory config = automationCore.getConfig();

        assertEq(config.registryMaxGasCap, 10_000_000);
        assertEq(config.sysRegistryMaxGasCap, 5_000_000);
        assertEq(config.automationBaseFeeWeiPerSec, 0.001 ether);
        assertEq(config.flatRegistrationFeeWei, 0.002 ether);
        assertEq(config.congestionBaseFeeWeiPerSec, 0.002 ether);
        assertEq(config.taskDurationCapSecs, 3600);
        assertEq(config.sysTaskDurationCapSecs, 3600);
        assertEq(config.cycleDurationSecs, 2000);
        assertEq(config.taskCapacity, 500);
        assertEq(config.sysTaskCapacity, 500);
        assertEq(config.congestionThresholdPercentage, 50);
        assertEq(config.congestionExponent, 2);
    }

    /// @dev Test to ensure reinitialization fails.
    function testInitializeRevertsIfReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        
        vm.prank(admin);    
        automationCore.initialize(
            3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2,
            500, 2000, 3600, 5_000_000, 500, vmSigner, address(erc20Supra)
        );
    }

    /// @dev Test to ensure initialization fails if zero address is passed as VM Signer.
    function testInitializeRevertsIfVmSignerZero() public {
        AutomationCore implementation = new AutomationCore();

        bytes memory initData = abi.encodeCall(
            AutomationCore.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether,
                2, 500, 2000, 3600, 5_000_000, 500,
                address(0),                             // VM Signer as zero
                address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationCore.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if ERC20Supra address is zero.
    function testInitializeRevertsIfErc20SupraIsZero() public {
        AutomationCore implementation = new AutomationCore();
        
        bytes memory initData = abi.encodeCall(
            AutomationCore.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether,
                2, 500, 2000, 3600, 5_000_000, 500, vmSigner, 
                address(0)                              // address(0) as ERC20Supra
            )
        );

        vm.expectRevert(IAutomationCore.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(implementation), initData);
    }
  
    /// @dev Test to ensure initialization fails if EOA is passed as ERC20Supra address.
    function testInitializeRevertsIfErc20SupraIsEoa() public {
        AutomationCore implementation = new AutomationCore();

        bytes memory initData = abi.encodeCall(
            AutomationCore.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether,
                2, 500, 2000, 3600, 5_000_000, 500, vmSigner, 
                admin                                   // EOA address as ERC20Supra
            )
        );

        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if task duration is <= cycle duration.
    function testInitializeRevertsIfInvalidTaskDuration() public {
        AutomationCore implementation = new AutomationCore();
        
        bytes memory initData = abi.encodeCall(
            AutomationCore.initialize,
            (
                2000,                                   // task duration
                10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2, 500,
                2000,                                   // cycle duration
                3600, 5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationCore.InvalidTaskDuration.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if registry max gas cap is zero.
    function testInitializeRevertsIfRegistryMaxGasCapZero() public {
        AutomationCore implementation = new AutomationCore();
        
        bytes memory initData = abi.encodeCall(
            AutomationCore.initialize,
            (
                3600,
                0,                                      // registry max gas cap
                0.001 ether, 0.002 ether, 50, 0.002 ether, 2, 500, 
                2000, 3600, 5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );
        
        vm.expectRevert(IAutomationCore.InvalidRegistryMaxGasCap.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if congestion threshold percentage is > 100.
    function testInitializeRevertsIfInvalidCongestionThreshold() public {
        AutomationCore implementation = new AutomationCore();
        
        bytes memory initData = abi.encodeCall(
            AutomationCore.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether,
                101,                                    // congestion threshold percentage > 100
                0.002 ether, 2, 500, 2000, 3600, 5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationCore.InvalidCongestionThreshold.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if congestion exponent is 0.
    function testInitializeRevertsIfCongestionExponentZero() public {
        AutomationCore implementation = new AutomationCore();
        
        bytes memory initData = abi.encodeCall(
            AutomationCore.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether,
                0,                                      // congestion exponent
                500, 2000, 3600, 5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationCore.InvalidCongestionExponent.selector);
        new ERC1967Proxy(address(implementation), initData);      
    }

    /// @dev Test to ensure initialization fails if task capacity is 0.
    function testInitializeRevertsIfTaskCapacityZero() public {
        AutomationCore implementation = new AutomationCore();

        bytes memory initData = abi.encodeCall(
            AutomationCore.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2,
                0,                                      // 0 as task capacity 
                2000, 3600, 5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationCore.InvalidTaskCapacity.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if cycle duration is 0.
    function testInitializeRevertsIfCycleDurationZero() public {
        AutomationCore implementation = new AutomationCore();
        
        bytes memory initData = abi.encodeCall(
            AutomationCore.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2, 500,
                0,                                      // cycle duration 
                3600, 5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationCore.InvalidCycleDuration.selector);
        new ERC1967Proxy(address(implementation), initData);
    }
    
    /// @dev Test to ensure initialization fails if system task duration is <= cycle duration.
    function testInitializeRevertsIfInvalidSysTaskDuration() public {
        AutomationCore implementation = new AutomationCore();

        bytes memory initData = abi.encodeCall(
            AutomationCore.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2, 500, 
                2000,                                   // cycle duration
                2000,                                   // system task duration
                5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationCore.InvalidSysTaskDuration.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if system registry max gas cap is 0.
    function testInitializeRevertsIfSysRegistryMaxGasCapZero() public {
        AutomationCore implementation = new AutomationCore();

        bytes memory initData = abi.encodeCall(
            AutomationCore.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2, 500, 2000, 3600,
                0,                                      // system registry max gas cap 
                500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationCore.InvalidSysRegistryMaxGasCap.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if system task capacity is 0.
    function testInitializeRevertsIfSysTaskCapacityZero() public {
        AutomationCore implementation = new AutomationCore();

        bytes memory initData = abi.encodeCall(
            AutomationCore.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether,
                2, 500, 2000, 3600, 5_000_000,
                0,                                      // system task capacity
                vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationCore.InvalidSysTaskCapacity.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'disableRegistration' ::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @dev Test to ensure 'disableRegistration' disables the registration.
    function testDisableRegistration() public {
        vm.prank(admin);
        automationCore.disableRegistration();

        assertFalse(automationCore.isRegistrationEnabled());
    }
    
    /// @dev Test to ensure 'disableRegistration' emits event 'TaskRegistrationDisabled'. 
    function testDisableRegistrationEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit AutomationCore.TaskRegistrationDisabled(false);

        testDisableRegistration();
    }

    /// @dev Test to ensure 'disableRegistration' reverts if registration is already disabled.
    function testDisableRegistrationRevertsIfAlreadyDisabled() public {
        // Disable registration
        testDisableRegistration();

        // Disable again → revert
        vm.expectRevert(IAutomationCore.AlreadyDisabled.selector);

        vm.prank(admin);
        automationCore.disableRegistration();
    }

    /// @dev Test to ensure 'disableRegistration' reverts if caller is not owner.
    function testDisableRegistrationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        
        vm.prank(alice);
        automationCore.disableRegistration();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'enableRegistration' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'enableRegistration' enables the registration.
    function testEnableRegistration() public {
        // Disable registration
        testDisableRegistration();

        // Enable registration
        vm.prank(admin);
        automationCore.enableRegistration();

        assertTrue(automationCore.isRegistrationEnabled());
    }

    /// @dev Test to ensure 'enableRegistration' emits event 'TaskRegistrationEnabled'.
    function testEnableRegistrationEmitsEvent() public {
        // Disable registration
        testDisableRegistration();

        vm.expectEmit(true, false, false, false);
        emit AutomationCore.TaskRegistrationEnabled(true);

        // Enable registration
        vm.prank(admin);
        automationCore.enableRegistration();
    }

    /// @dev Test to ensure 'enableRegistration' reverts if registration is already enabled.
    function testEnableRegistrationRevertsIfAlreadyEnabled() public {
        // Already enabled in initialize()
        vm.expectRevert(IAutomationCore.AlreadyEnabled.selector);

        vm.prank(admin);
        automationCore.enableRegistration();
    }

    /// @dev Test to ensure 'enableRegistration' reverts if caller is not owner.
    function testEnableRegistrationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        
        vm.prank(alice);
        automationCore.enableRegistration();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'disableAutomation' ::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @dev Test to ensure 'disableAutomation' disables the automation.
    function testDisableAutomation() public {
        // Already enabled in initialize()
        vm.prank(admin);
        automationCore.disableAutomation();

        assertFalse(automationCore.isAutomationEnabled());
    }

    /// @dev Test to ensure 'disableAutomation' emits event 'AutomationDisabled'.
    function testDisableAutomationEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit AutomationCore.AutomationDisabled(false);

        vm.prank(admin);
        automationCore.disableAutomation();
    }

    /// @dev Test to ensure 'disableAutomation' reverts if automation is already disabled.
    function testDisableAutomationRevertsIfAlreadyDisabled() public {
        // Disable automation
        testDisableAutomation();

        // Disable again → revert
        vm.expectRevert(IAutomationCore.AlreadyDisabled.selector);

        vm.prank(admin);
        automationCore.disableAutomation();
    }

    /// @dev Test to ensure 'disableAutomation' reverts if caller is not owner.
    function testDisableAutomationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        automationCore.disableAutomation();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'enableAutomation' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'enableAutomation' enables the automation.
    function testEnableAutomation() public {
        // Disable automation
        testDisableAutomation();

        // Enable automation
        vm.prank(admin);
        automationCore.enableAutomation();

        assertTrue(automationCore.isAutomationEnabled());
    }

    /// @dev Test to ensure 'enableAutomation' emits event 'AutomationEnabled'.
    function testEnableAutomationEmitsEvent() public {
        // Disable automation
        testDisableAutomation();

        vm.expectEmit(true, false, false, false);
        emit AutomationCore.AutomationEnabled(true);

        vm.prank(admin);
        automationCore.enableAutomation();
    }

    /// @dev Test to ensure 'enableAutomation' reverts if automation is already enabled.
    function testEnableAutomationRevertsIfAlreadyEnabled() public {
        // Already enabled in initialize()
        vm.expectRevert(IAutomationCore.AlreadyEnabled.selector);

        vm.prank(admin);
        automationCore.enableAutomation();
    }

    /// @dev Test to ensure 'enableAutomation' reverts if caller is not owner.
    function testEnableAutomationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        automationCore.enableAutomation();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'setAutomationRegistry' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Helper function that deploys AutomationRegistry and returns its address.
    function deployAutomationRegistry() internal returns (address) {
        // Deploy AutomationRegistry proxy
        AutomationRegistry registryImpl = new AutomationRegistry();
        bytes memory registryInitData = abi.encodeCall(AutomationRegistry.initialize,(address(automationCore)));
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);

        return address(registryProxy);
    }

    /// @dev Test to ensure 'setAutomationRegistry' updates the automation registry address.
    function testSetAutomationRegistry() public {
        address registryAddr = deployAutomationRegistry(); 
        
        vm.prank(admin);
        automationCore.setAutomationRegistry(registryAddr);

        assertEq(automationCore.getAutomationRegistry(), registryAddr);
    }

    /// @dev Test to ensure 'setAutomationRegistry' emits event 'AutomationRegistryUpdated'.
    function testSetAutomationRegistryEmitsEvent() public {
        address oldRegistry = automationCore.getAutomationRegistry();
        address registryAddr = deployAutomationRegistry();

        vm.expectEmit(true, true, false, false);
        emit AutomationCore.AutomationRegistryUpdated(oldRegistry, registryAddr);

        vm.prank(admin);
        automationCore.setAutomationRegistry(registryAddr);
    }

    /// @dev Test to ensure 'setAutomationRegistry' reverts if caller is not owner.
    function testSetAutomationRegistryRevertsIfNotOwner() public {
        address registryAddr = deployAutomationRegistry();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        automationCore.setAutomationRegistry(registryAddr);
    }

    /// @dev Test to ensure 'setAutomationRegistry' reverts if zero address is passed.
    function testSetAutomationRegistryRevertsIfZeroAddress() public {
        vm.expectRevert(IAutomationCore.AddressCannotBeZero.selector);

        vm.prank(admin);
        automationCore.setAutomationRegistry(address(0));
    }

    /// @dev Test to ensure 'setAutomationRegistry' reverts if EOA is passed.
    function testSetAutomationRegistryRevertsIfEoa() public {
        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);

        vm.prank(admin);
        automationCore.setAutomationRegistry(alice);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'setAutomationController' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Helper function that deploys AutomationController and returns its address.
    function deployAutomationController() internal returns (address) {
        // Deploy AutomationController proxy
        AutomationController controllerImpl = new AutomationController();
        bytes memory controllerInitData = abi.encodeCall(AutomationController.initialize,(address(automationCore), address(registry)));
        ERC1967Proxy controllerProxy = new ERC1967Proxy(address(controllerImpl), controllerInitData);

        return address(controllerProxy);
    }

    /// @dev Test to ensure 'setAutomationController' updates the automation controller address.
    function testSetAutomationController() public {
        address controller = deployAutomationController(); 
        
        vm.prank(admin);
        automationCore.setAutomationController(controller);

        assertEq(automationCore.getAutomationController(), controller);
    }

    /// @dev Test to ensure 'setAutomationController' emits event 'AutomationControllerUpdated'.
    function testSetAutomationControllerEmitsEvent() public {
        address oldController = automationCore.getAutomationController();
        address controller = deployAutomationController();

        vm.expectEmit(true, true, false, false);
        emit AutomationCore.AutomationControllerUpdated(oldController, controller);

        vm.prank(admin);
        automationCore.setAutomationController(controller);
    }

    /// @dev Test to ensure 'setAutomationController' reverts if caller is not owner.
    function testSetAutomationControllerRevertsIfNotOwner() public {
        address controller = deployAutomationController();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        automationCore.setAutomationController(controller);
    }

    /// @dev Test to ensure 'setAutomationController' reverts if zero address is passed.
    function testSetAutomationControllerRevertsIfZeroAddress() public {
        vm.expectRevert(IAutomationCore.AddressCannotBeZero.selector);

        vm.prank(admin);
        automationCore.setAutomationController(address(0));
    }

    /// @dev Test to ensure 'setAutomationController' reverts if EOA is passed.
    function testSetAutomationControllerRevertsIfEoa() public {
        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);

        vm.prank(admin);
        automationCore.setAutomationController(alice);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'setVmSigner' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'setVmSigner' updates the VM Signer address.
    function testSetVmSigner() public {
        address newVmSigner = address(0x100);

        vm.prank(admin);
        automationCore.setVmSigner(newVmSigner);

        assertEq(automationCore.getVmSigner(), newVmSigner);
    }

    /// @dev Test to ensure 'setVmSigner' emits event 'VmSignerUpdated'.
    function testSetVmSignerEmitsEvent() public {
        address oldVmSigner = automationCore.getVmSigner();
        address newVmSigner = address(0x100);

        vm.expectEmit(true, true, false, false);
        emit AutomationCore.VmSignerUpdated(oldVmSigner, newVmSigner);

        vm.prank(admin);
        automationCore.setVmSigner(newVmSigner);
    }

    /// @dev Test to ensure 'setVmSigner' reverts if zero address is passed.
    function testSetVmSignerRevertsIfZeroAddress() public {
        vm.expectRevert(IAutomationCore.AddressCannotBeZero.selector);

        vm.prank(admin);
        automationCore.setVmSigner(address(0));
    }

    /// @dev Test to ensure 'setVmSigner' reverts if caller is not owner.
    function testSetVmSignerRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        automationCore.setVmSigner(address(0x100));
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'setErc20Supra' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'setErc20Supra' updates the ERC20Supra address. 
    function testSetErc20Supra() public {
        ERC20Supra supraErc20 = new ERC20Supra(msg.sender);

        vm.prank(admin);
        automationCore.setErc20Supra(address(supraErc20));

        assertEq(automationCore.erc20Supra(), address(supraErc20));
    }

    /// @dev Test to ensure 'setErc20Supra' emits event 'Erc20SupraUpdated'. 
    function testSetErc20SupraEmitsEvent() public {
        address oldAddr = automationCore.erc20Supra();
        ERC20Supra supraErc20 = new ERC20Supra(msg.sender);

        vm.expectEmit(true, true, false, false);
        emit AutomationCore.Erc20SupraUpdated(oldAddr, address(supraErc20));

        vm.prank(admin);
        automationCore.setErc20Supra(address(supraErc20));
    }

    /// @dev Test to ensure 'setErc20Supra' reverts if zero address is passed. 
    function testSetErc20SupraRevertsIfZeroAddress() public {
        vm.expectRevert(IAutomationCore.AddressCannotBeZero.selector);

        vm.prank(admin);
        automationCore.setErc20Supra(address(0));
    }

    /// @dev Test to ensure 'setErc20Supra' reverts if EOA is passed. 
    function testSetErc20SupraRevertsIfEoa() public {
        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);

        vm.prank(admin);
        automationCore.setErc20Supra(alice);
    }

    /// @dev Test to ensure 'setErc20Supra' reverts if caller is not owner. 
    function testSetErc20SupraRevertsIfNotOwner() public {
        ERC20Supra supraErc20 = new ERC20Supra(msg.sender);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        automationCore.setErc20Supra(address(supraErc20));
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'updateConfigBuffer' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Helper function that returns a valid config.
    function validConfig() internal pure returns (LibConfig.ConfigDetails memory cfg) {
        cfg = LibConfig.ConfigDetails(
            10_000_000,                 // registryMaxGasCap
            5_000_000,                  // sysRegistryMaxGasCap
            0.001 ether,                // automationBaseFeeWeiPerSec
            0.002 ether,                // flatRegistrationFeeWei
            0.002 ether,                // congestionBaseFeeWeiPerSec
            3600,                       // taskDurationCapSecs
            3600,                       // sysTaskDurationCapSecs
            2000,                       // cycleDurationSecs
            500,                        // taskCapacity
            500,                        // sysTaskCapacity
            55,                         // congestionThresholdPercentage
            3                           // congestionExponent
        );
    }

    /// @dev Test to ensure 'updateConfigBuffer' updates the config buffer.
    function testUpdateConfigBuffer() public {
        LibConfig.ConfigDetails memory cfg = validConfig();
    
        vm.prank(admin);
        automationCore.updateConfigBuffer(
            cfg.taskDurationCapSecs,
            cfg.registryMaxGasCap,
            cfg.automationBaseFeeWeiPerSec,
            cfg.flatRegistrationFeeWei,
            cfg.congestionThresholdPercentage,
            cfg.congestionBaseFeeWeiPerSec,
            cfg.congestionExponent,
            cfg.taskCapacity,
            cfg.cycleDurationSecs,
            cfg.sysTaskDurationCapSecs,
            cfg.sysRegistryMaxGasCap,
            cfg.sysTaskCapacity
        );
    
        // Pending config should be updated
        LibConfig.ConfigDetails memory pendingCfg = automationCore.getPendingConfig();
        assertEq(pendingCfg.taskDurationCapSecs, cfg.taskDurationCapSecs);
        assertEq(pendingCfg.registryMaxGasCap, cfg.registryMaxGasCap);
        assertEq(pendingCfg.automationBaseFeeWeiPerSec, cfg.automationBaseFeeWeiPerSec);
        assertEq(pendingCfg.flatRegistrationFeeWei, cfg.flatRegistrationFeeWei);
        assertEq(pendingCfg.congestionThresholdPercentage, cfg.congestionThresholdPercentage);
        assertEq(pendingCfg.congestionBaseFeeWeiPerSec, cfg.congestionBaseFeeWeiPerSec);
        assertEq(pendingCfg.congestionExponent, cfg.congestionExponent);
        assertEq(pendingCfg.taskCapacity, cfg.taskCapacity);
        assertEq(pendingCfg.cycleDurationSecs, cfg.cycleDurationSecs);
        assertEq(pendingCfg.sysTaskDurationCapSecs, cfg.sysTaskDurationCapSecs);
        assertEq(pendingCfg.sysRegistryMaxGasCap, cfg.sysRegistryMaxGasCap);
        assertEq(pendingCfg.sysTaskCapacity, cfg.sysTaskCapacity);
    }

    /// @dev Test to ensure 'updateConfigBuffer' emits event 'ConfigBufferUpdated'.
    function testUpdateConfigBufferEmitsEvent() public {
        LibConfig.ConfigDetails memory cfg = validConfig();

        vm.expectEmit(true, false, false, false);
        emit AutomationCore.ConfigBufferUpdated(cfg);
        
        vm.prank(admin);
        automationCore.updateConfigBuffer(
            cfg.taskDurationCapSecs,
            cfg.registryMaxGasCap,
            cfg.automationBaseFeeWeiPerSec,
            cfg.flatRegistrationFeeWei,
            cfg.congestionThresholdPercentage,
            cfg.congestionBaseFeeWeiPerSec,
            cfg.congestionExponent,
            cfg.taskCapacity,
            cfg.cycleDurationSecs,
            cfg.sysTaskDurationCapSecs,
            cfg.sysRegistryMaxGasCap,
            cfg.sysTaskCapacity
        );
    }

    /// @dev Test to ensure 'updateConfigBuffer' reverts if caller is not owner.
    function testUpdateConfigBufferRevertsIfNotOwner() public {
        LibConfig.ConfigDetails memory cfg = validConfig();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        automationCore.updateConfigBuffer(
            cfg.taskDurationCapSecs,
            cfg.registryMaxGasCap,
            cfg.automationBaseFeeWeiPerSec,
            cfg.flatRegistrationFeeWei,
            cfg.congestionThresholdPercentage,
            cfg.congestionBaseFeeWeiPerSec,
            cfg.congestionExponent,
            cfg.taskCapacity,
            cfg.cycleDurationSecs,
            cfg.sysTaskDurationCapSecs,
            cfg.sysRegistryMaxGasCap,
            cfg.sysTaskCapacity
        );
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'withdrawFees' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'withdrawFees' reverts if amount is zero.
    function testWithdrawFeesRevertsIfAmountZero() public {
        vm.prank(admin);

        vm.expectRevert(IAutomationCore.InvalidAmount.selector);
        automationCore.withdrawFees(0, admin);
    }

    /// @dev Test to ensure 'withdrawFees' reverts if recipient address is zero.
    function testWithdrawFeesRevertsIfRecipientAddressZero() public {
        vm.prank(admin);

        vm.expectRevert(IAutomationCore.AddressCannotBeZero.selector);
        automationCore.withdrawFees(1 ether, address(0));
    }

    /// @dev Test to ensure 'withdrawFees' reverts if contract has insufficient balance.
    function testWithdrawFeesRevertsIfInsufficientBalance() public {
        vm.expectRevert(IAutomationCore.InsufficientBalance.selector);

        vm.prank(admin);
        automationCore.withdrawFees(1 ether, admin);
    }

    /// @dev Test to ensure 'withdrawFees' reverts if request amount exceeds the locked balance.
    function testWithdrawFeesRevertsIfRequestExceedsLockedBalance() public {
        registerUST();

        vm.expectRevert(IAutomationCore.RequestExceedsLockedBalance.selector);

        vm.prank(admin);
        automationCore.withdrawFees(0.04 ether, admin);
    }

    /// @dev Test to ensure 'withdrawFees' reverts if caller is not owner.
    function testWithdrawFeesRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        automationCore.withdrawFees(1 ether, admin);
    }

    /// @dev Test to ensure 'withdrawFees' withdraws the requested amount and updates the balance.
    function testWithdrawFees() public {
        registerUST();

        assertEq(erc20Supra.balanceOf(admin), 0);
        assertEq(erc20Supra.balanceOf(address(automationCore)), 0.502 ether);

        vm.prank(admin);
        automationCore.withdrawFees(0.002 ether, admin);

        assertEq(erc20Supra.balanceOf(admin), 0.002 ether);
        assertEq(erc20Supra.balanceOf(address(automationCore)), 0.5 ether);
    }
    
    /// @dev Test to ensure 'withdrawFees' emits event 'RegistryFeeWithdrawn'.
    function testWithdrawFeesEmitsEvent() public {
        registerUST();

        vm.expectEmit(true, true, false, false);
        emit AutomationCore.RegistryFeeWithdrawn(admin, 0.002 ether);

        vm.prank(admin);
        automationCore.withdrawFees(0.002 ether, admin);
    }

    /// @dev Helper function to return payload.
    /// @param _value Value to be sent along with the transaction.
    /// @param _target Address of the destination smart contract.
    function createPayload(uint128 _value, address _target) private pure returns (bytes memory) {
        LibConfig.AccessListEntry[] memory accessList = new LibConfig.AccessListEntry[](2);
        
        bytes32[] memory keys = new bytes32[](2); 
        keys[0] = bytes32(uint256(0));
        keys[1] = bytes32(uint256(1));

        accessList[0] = LibConfig.AccessListEntry({
            addr: address(0x1111),
            storageKeys: keys
        });

        accessList[1] = LibConfig.AccessListEntry({
            addr: address(0x2222),
            storageKeys: keys
        });

        bytes memory callData = abi.encodeCall(ERC20Supra.erc20SupraToNative, 100);
        bytes memory payload = abi.encode(_value, _target, callData, accessList);

        return payload;   
    }

    /// @dev Helper function to register a UST.
    function registerUST() private {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 
        
        vm.startPrank(alice);
        erc20Supra.nativeToErc20Supra{value: 5 ether}();
        erc20Supra.approve(address(automationCore), type(uint256).max);

        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            4,
            0,
            auxData
        );
        vm.stopPrank();
    }
}