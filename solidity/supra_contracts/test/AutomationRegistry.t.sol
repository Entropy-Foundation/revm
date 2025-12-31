// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {AutomationRegistry} from "../src/AutomationRegistry.sol";
import {AutomationController} from "../src/AutomationController.sol";
import {IAutomationRegistry} from "../src/IAutomationRegistry.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {LibRegistry} from "../src/LibRegistry.sol";
import {LibCommonUtils} from "../src/LibCommonUtils.sol";

contract AutomationRegistryTest is Test {
    AutomationRegistry impl;                    // implementation logic contract
    AutomationRegistry registry;                // registry instance on proxy address
    ERC1967Proxy proxy;                         // proxy contract
    ERC20Supra erc20Supra;                      // ERC20Supra contract

    address admin = address(0xA11CE);
    address vmSigner = address(0x5355500000000000000000000000000000000000);
    address alice = address(0x123);
    address bob = address(0x456);

    /// @dev Sets up initial state for testing.
    /// @dev Sets balance of 'alice' to 100 ether.
    /// @dev Deploys ERC20Supra and AutomationRegistry contracts. 
    /// @dev Initializes AutomationRegistry with required parameters. 
    function setUp() public {
        vm.deal(alice, 100 ether);

        vm.startPrank(admin);
        erc20Supra = new ERC20Supra(msg.sender);
        impl = new AutomationRegistry();

        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
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

        proxy = new ERC1967Proxy(address(impl), initData);
        registry = AutomationRegistry(address(proxy));
        vm.stopPrank();
    }

    /// @dev Test to ensure all state variables are initialized correctly.
    function testInitialize() public view {
        assertEq(registry.owner(), admin);

        assertEq(registry.getNextCycleRegistryMaxGasCap(), 10_000_000);
        assertEq(registry.getNextCycleSysRegistryMaxGasCap(), 5_000_000);
        assertEq(registry.getAutomationController(), address(0));
        assertTrue(registry.isRegistrationEnabled());
        assertTrue(registry.isAutomationEnabled());
        assertEq(registry.getVmSigner(), vmSigner);
        assertEq(registry.erc20Supra(), address(erc20Supra));

        LibRegistry.ConfigDetails memory config = registry.getConfig();

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

        assertEq(registry.owner(), admin);
    }

    /// @dev Test to ensure reinitialization fails.
    function testInitializeRevertsIfReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        
        vm.prank(admin);    
        registry.initialize(
            3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2,
            500, 2000, 3600, 5_000_000, 500, vmSigner, address(erc20Supra)
        );
    }
    /// @dev Test to ensure initialization fails if zero address is passed as VM Signer.
    function testInitializeRevertsIfVmSignerZero() public {
        AutomationRegistry implementation = new AutomationRegistry();

        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether,
                2, 500, 2000, 3600, 5_000_000, 500,
                address(0),                             // VM Signer as zero
                address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if ERC20Supra address is zero.
    function testInitializeRevertsIfErc20SupraIsZero() public {
        AutomationRegistry implementation = new AutomationRegistry();
        
        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether,
                2, 500, 2000, 3600, 5_000_000, 500, vmSigner, 
                address(0)                              // address(0) as ERC20Supra
            )
        );

        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(implementation), initData);
    }
  
    /// @dev Test to ensure initialization fails if EOA is passed as ERC20Supra address.
    function testInitializeRevertsIfErc20SupraIsEoa() public {
        AutomationRegistry implementation = new AutomationRegistry();

        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether,
                2, 500, 2000, 3600, 5_000_000, 500, vmSigner, 
                admin                                   // EOA address as ERC20Supra
            )
        );

        vm.expectRevert(IAutomationRegistry.AddressCannotBeEOA.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if task duration is <= cycle duration.
    function testInitializeRevertsIfInvalidTaskDuration() public {
        AutomationRegistry implementation = new AutomationRegistry();
        
        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                2000,                                   // task duration
                10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2, 500,
                2000,                                   // cycle duration
                3600, 5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationRegistry.InvalidTaskDuration.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if registry max gas cap is zero.
    function testInitializeRevertsIfRegistryMaxGasCapZero() public {
        AutomationRegistry implementation = new AutomationRegistry();
        
        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600,
                0,                                      // registry max gas cap
                0.001 ether, 0.002 ether, 50, 0.002 ether, 2, 500, 
                2000, 3600, 5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );
        
        vm.expectRevert(IAutomationRegistry.InvalidRegistryMaxGasCap.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if congestion threshold percentage is > 100.
    function testInitializeRevertsIfInvalidCongestionThreshold() public {
        AutomationRegistry implementation = new AutomationRegistry();
        
        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether,
                101,                                    // congestion threshold percentage > 100
                0.002 ether, 2, 500, 2000, 3600, 5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationRegistry.InvalidCongestionThreshold.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if congestion exponent is 0.
    function testInitializeRevertsIfCongestionExponentZero() public {
        AutomationRegistry implementation = new AutomationRegistry();
        
        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether,
                0,                                      // congestion exponent
                500, 2000, 3600, 5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationRegistry.InvalidCongestionExponent.selector);
        new ERC1967Proxy(address(implementation), initData);      
    }

    /// @dev Test to ensure initialization fails if task capacity is 0.
    function testInitializeRevertsIfTaskCapacityZero() public {
        AutomationRegistry implementation = new AutomationRegistry();

        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2,
                0,                                      // 0 as task capacity 
                2000, 3600, 5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationRegistry.InvalidTaskCapacity.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if cycle duration is 0.
    function testInitializeRevertsIfCycleDurationZero() public {
        AutomationRegistry implementation = new AutomationRegistry();
        
        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2, 500,
                0,                                      // cycle duration 
                3600, 5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationRegistry.InvalidCycleDuration.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if system task duration is <= cycle duration.
    function testInitializeRevertsIfInvalidSysTaskDuration() public {
        AutomationRegistry implementation = new AutomationRegistry();

        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2, 500, 
                2000,                                   // cycle duration
                2000,                                   // system task duration
                5_000_000, 500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationRegistry.InvalidSysTaskDuration.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if system registry max gas cap is 0.
    function testInitializeRevertsIfSysRegistryMaxGasCapZero() public {
        AutomationRegistry implementation = new AutomationRegistry();

        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2, 500, 2000, 3600,
                0,                                      // system registry max gas cap 
                500, vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationRegistry.InvalidSysRegistryMaxGasCap.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /// @dev Test to ensure initialization fails if system task capacity is 0.
    function testInitializeRevertsIfSysTaskCapacityZero() public {
        AutomationRegistry implementation = new AutomationRegistry();

        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether,
                2, 500, 2000, 3600, 5_000_000,
                0,                                      // system task capacity
                vmSigner, address(erc20Supra)
            )
        );

        vm.expectRevert(IAutomationRegistry.InvalidSysTaskCapacity.selector);
        new ERC1967Proxy(address(implementation), initData);
    }
    
    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'disableRegistration' ::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @dev Test to ensure 'disableRegistration' disables the registration.
    function testDisableRegistration() public {
        vm.prank(admin);
        registry.disableRegistration();

        assertFalse(registry.isRegistrationEnabled());
    }
    
    /// @dev Test to ensure 'disableRegistration' emits event 'TaskRegistrationDisabled'. 
    function testDisableRegistrationEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit AutomationRegistry.TaskRegistrationDisabled(false);

        testDisableRegistration();
    }

    /// @dev Test to ensure 'disableRegistration' reverts if registration is already disabled.
    function testDisableRegistrationRevertsIfAlreadyDisabled() public {
        // Disable registration
        testDisableRegistration();

        // Disable again → revert
        vm.expectRevert(IAutomationRegistry.AlreadyDisabled.selector);

        vm.prank(admin);
        registry.disableRegistration();
    }

    /// @dev Test to ensure 'disableRegistration' reverts if caller is not owner.
    function testDisableRegistrationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        
        vm.prank(alice);
        registry.disableRegistration();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'enableRegistration' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'enableRegistration' enables the registration.
    function testEnableRegistration() public {
        // Disable registration
        testDisableRegistration();

        // Enable registration
        vm.prank(admin);
        registry.enableRegistration();

        assertTrue(registry.isRegistrationEnabled());
    }

    /// @dev Test to ensure 'enableRegistration' emits event 'TaskRegistrationEnabled'.
    function testEnableRegistrationEmitsEvent() public {
        // Disable registration
        testDisableRegistration();

        vm.expectEmit(true, false, false, false);
        emit AutomationRegistry.TaskRegistrationEnabled(true);

        // Enable registration
        vm.prank(admin);
        registry.enableRegistration();
    }

    /// @dev Test to ensure 'enableRegistration' reverts if registration is already enabled.
    function testEnableRegistrationRevertsIfAlreadyEnabled() public {
        // Already enabled in initialize()
        vm.expectRevert(IAutomationRegistry.AlreadyEnabled.selector);

        vm.prank(admin);
        registry.enableRegistration();
    }

    /// @dev Test to ensure 'enableRegistration' reverts if caller is not owner.
    function testEnableRegistrationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        
        vm.prank(alice);
        registry.enableRegistration();
    }
    
    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'disableAutomation' ::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @dev Test to ensure 'disableAutomation' disables the automation.
    function testDisableAutomation() public {
        testSetAutomationController();

        // Already enabled in initialize()
        vm.prank(admin);
        registry.disableAutomation();

        assertFalse(registry.isAutomationEnabled());
    }

    /// @dev Test to ensure 'disableAutomation' emits event 'AutomationDisabled'.
    function testDisableAutomationEmitsEvent() public {
        testSetAutomationController();

        vm.expectEmit(true, false, false, false);
        emit AutomationRegistry.AutomationDisabled(false);

        vm.prank(admin);
        registry.disableAutomation();
    }

    /// @dev Test to ensure 'disableAutomation' reverts if automation is already disabled.
    function testDisableAutomationRevertsIfAlreadyDisabled() public {
        // Disable automation
        testDisableAutomation();

        // Disable again → revert
        vm.expectRevert(IAutomationRegistry.AlreadyDisabled.selector);

        vm.prank(admin);
        registry.disableAutomation();
    }

    /// @dev Test to ensure 'disableAutomation' reverts if caller is not owner.
    function testDisableAutomationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.disableAutomation();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'enableAutomation' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'enableAutomation' enables the automation.
    function testEnableAutomation() public {
        // Disable automation
        testDisableAutomation();

        // Enable automation
        vm.prank(admin);
        registry.enableAutomation();

        assertTrue(registry.isAutomationEnabled());
    }

    /// @dev Test to ensure 'enableAutomation' emits event 'AutomationEnabled'.
    function testEnableAutomationEmitsEvent() public {
        // Disable automation
        testDisableAutomation();

        vm.expectEmit(true, false, false, false);
        emit AutomationRegistry.AutomationEnabled(true);

        vm.prank(admin);
        registry.enableAutomation();
    }

    /// @dev Test to ensure 'enableAutomation' reverts if automation is already enabled.
    function testEnableAutomationRevertsIfAlreadyEnabled() public {
        // Already enabled in initialize()
        vm.expectRevert(IAutomationRegistry.AlreadyEnabled.selector);

        vm.prank(admin);
        registry.enableAutomation();
    }

    /// @dev Test to ensure 'enableAutomation' reverts if caller is not owner.
    function testEnableAutomationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.enableAutomation();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'setAutomationController' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Helper function that deploys AutomationController and returns its address.
    function deployAutomationController() internal returns (address) {
        // Deploy AutomationController proxy
        AutomationController controllerImpl = new AutomationController();
        bytes memory controllerInitData = abi.encodeCall(AutomationController.initialize,(address(registry)));
        ERC1967Proxy controllerProxy = new ERC1967Proxy(address(controllerImpl), controllerInitData);

        return address(controllerProxy);
    }

    /// @dev Test to ensure 'setAutomationController' updates the automation controller address.
    function testSetAutomationController() public {
        address controller = deployAutomationController(); 
        
        vm.prank(admin);
        registry.setAutomationController(controller);

        assertEq(registry.getAutomationController(), controller);
    }

    /// @dev Test to ensure 'setAutomationController' emits event 'AutomationControllerUpdated'.
    function testSetAutomationControllerEmitsEvent() public {
        address oldController = registry.getAutomationController();
        address controller = deployAutomationController();

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.AutomationControllerUpdated(oldController, controller);

        vm.prank(admin);
        registry.setAutomationController(controller);
    }

    /// @dev Test to ensure 'setAutomationController' reverts if caller is not owner.
    function testSetAutomationControllerRevertsIfNotOwner() public {
        address controller = deployAutomationController();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.setAutomationController(controller);
    }

    /// @dev Test to ensure 'setAutomationController' reverts if zero address is passed.
    function testSetAutomationControllerRevertsIfZeroAddress() public {
        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);

        vm.prank(admin);
        registry.setAutomationController(address(0));
    }

    /// @dev Test to ensure 'setAutomationController' reverts if EOA is passed.
    function testSetAutomationControllerRevertsIfEoa() public {
        vm.expectRevert(IAutomationRegistry.AddressCannotBeEOA.selector);

        vm.prank(admin);
        registry.setAutomationController(alice);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'setVmSigner' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'setVmSigner' updates the VM Signer address.
    function testSetVmSigner() public {
        address newVmSigner = address(0x100);

        vm.prank(admin);
        registry.setVmSigner(newVmSigner);

        assertEq(registry.getVmSigner(), newVmSigner);
    }

    /// @dev Test to ensure 'setVmSigner' emits event 'VmSignerUpdated'.
    function testSetVmSignerEmitsEvent() public {
        address oldVmSigner = registry.getVmSigner();
        address newVmSigner = address(0x100);

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.VmSignerUpdated(oldVmSigner, newVmSigner);

        vm.prank(admin);
        registry.setVmSigner(newVmSigner);
    }

    /// @dev Test to ensure 'setVmSigner' reverts if zero address is passed.
    function testSetVmSignerRevertsIfZeroAddress() public {
        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);

        vm.prank(admin);
        registry.setVmSigner(address(0));
    }

    /// @dev Test to ensure 'setVmSigner' reverts if caller is not owner.
    function testSetVmSignerRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        registry.setVmSigner(address(0x100));
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'setErc20Supra' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'setErc20Supra' updates the ERC20Supra address. 
    function testSetErc20Supra() public {
        ERC20Supra supra = new ERC20Supra(msg.sender);

        vm.prank(admin);
        registry.setErc20Supra(address(supra));

        assertEq(registry.erc20Supra(), address(supra));
    }

    /// @dev Test to ensure 'setErc20Supra' emits event 'Erc20SupraUpdated'. 
    function testSetErc20SupraEmitsEvent() public {
        address oldAddr = registry.erc20Supra();
        ERC20Supra supra = new ERC20Supra(msg.sender);

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.Erc20SupraUpdated(oldAddr, address(supra));

        vm.prank(admin);
        registry.setErc20Supra(address(supra));
    }

    /// @dev Test to ensure 'setErc20Supra' reverts if zero address is passed. 
    function testSetErc20SupraRevertsIfZeroAddress() public {
        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);

        vm.prank(admin);
        registry.setErc20Supra(address(0));
    }

    /// @dev Test to ensure 'setErc20Supra' reverts if EOA is passed. 
    function testSetErc20SupraRevertsIfEoa() public {
        vm.expectRevert(IAutomationRegistry.AddressCannotBeEOA.selector);

        vm.prank(admin);
        registry.setErc20Supra(alice);
    }

    /// @dev Test to ensure 'setErc20Supra' reverts if caller is not owner. 
    function testSetErc20SupraRevertsIfNotOwner() public {
        ERC20Supra supra = new ERC20Supra(msg.sender);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        registry.setErc20Supra(address(supra));
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'setColdWallet' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'setColdWallet' updates the cold wallet address.
    function testSetColdWallet() public {
        vm.prank(admin);
        registry.setColdWallet(address(0x1001));

        assertEq(registry.getColdWallet(), address(0x1001));
    }

    /// @dev Test to ensure 'setColdWallet' emits event 'ColdWalletUpdated'.
    function testSetColdWalletEmitsEvent() public {
        address oldColdWallet = registry.getColdWallet();
    
        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.ColdWalletUpdated(oldColdWallet, address(0x1001));
    
        vm.prank(admin);
        registry.setColdWallet(address(0x1001));
    }

    /// @dev Test to ensure 'setColdWallet' reverts if zero address is passed.
    function testSetColdWalletRevertsIfZeroAddress() public {
        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);

        vm.prank(admin);
        registry.setColdWallet(address(0));
    }

    /// @dev Test to ensure 'setColdWallet' reverts if caller is not owner.
    function testSetColdWalletRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        registry.setColdWallet(address(0x1001));
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'grantAuthorization' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'grantAuthorization' grants authorization to an address.
    function testGrantAuthorization() public {
        vm.prank(admin);
        registry.grantAuthorization(bob);

        assertTrue(registry.isAuthorizedSubmitter(bob));
    }

    /// @dev Test to ensure 'grantAuthorization' emits event 'AuthorizationGranted'.
    function testGrantAuthorizationEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.AuthorizationGranted(bob, block.timestamp);

        vm.prank(admin);
        registry.grantAuthorization(bob);
    }

    /// @dev Test to ensure 'grantAuthorization' reverts if address is already authorized.
    function testGrantAuthorizationRevertsIfAlreadyAuthorised() public {
        // Grant authorization to bob
        testGrantAuthorization();

        vm.expectRevert(IAutomationRegistry.AddressAlreadyExists.selector);

        vm.prank(admin);
        registry.grantAuthorization(bob);
    }

    /// @dev Test to ensure 'grantAuthorization' reverts if caller is not owner.
    function testGrantAuthorizationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.grantAuthorization(bob);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'revokeAuthorization' ::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @dev Test to ensure 'revokeAuthorization' revokes authorization from an address.
    function testRevokeAuthorization() public {
        // Grant authorization to bob
        testGrantAuthorization();

        // Revoke authorization
        vm.prank(admin);
        registry.revokeAuthorization(bob);

        assertFalse(registry.isAuthorizedSubmitter(bob));
    }

    /// @dev Test to ensure 'revokeAuthorization' emits event 'AuthorizationRevoked'.
    function testRevokeAuthorizationEmitsEvent() public {
        // Grant authorization to bob
        testGrantAuthorization();

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.AuthorizationRevoked(bob, block.timestamp);

        vm.prank(admin);
        registry.revokeAuthorization(bob);
    }

    /// @dev Test to ensure 'revokeAuthorization' reverts if address is not authorised.
    function testRevokeAuthorizationRevertsIfNotAuthorised() public {
        vm.expectRevert(IAutomationRegistry.AddressDoesNotExist.selector);

        vm.prank(admin);
        registry.revokeAuthorization(bob);
    }

    /// @dev Test to ensure 'revokeAuthorization' reverts if caller is not owner.
    function testRevokeAuthorizationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.revokeAuthorization(bob);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'updateConfigBuffer' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Helper function that returns a valid config.
    function validConfig() internal pure returns (LibRegistry.ConfigDetails memory cfg) {
        cfg = LibRegistry.ConfigDetails(
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
        LibRegistry.ConfigDetails memory cfg = validConfig();
    
        vm.prank(admin);
        registry.updateConfigBuffer(
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
        LibRegistry.ConfigDetails memory pendingCfg = registry.getPendingConfig();
        assertTrue(registry.ifConfigBufferExists());
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
        LibRegistry.ConfigDetails memory cfg = validConfig();

        vm.expectEmit(true, false, false, false);
        emit AutomationRegistry.ConfigBufferUpdated(cfg);
        
        vm.prank(admin);
        registry.updateConfigBuffer(
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
        LibRegistry.ConfigDetails memory cfg = validConfig();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.updateConfigBuffer(
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

    /// @dev Test to ensure 'withdrawFees' reverts if cold wallet is not set.
    function testWithdrawFeesRevertsIfColdWalletNotSet() public {
        vm.prank(admin);

        vm.expectRevert(IAutomationRegistry.ColdWalletNotSet.selector);
        registry.withdrawFees(1 ether);
    }

    /// @dev Test to ensure 'withdrawFees' reverts if contract has insufficient balance.
    function testWithdrawFeesRevertsIfInsufficientBalance() public {
        // Set cold wallet
        vm.prank(admin);
        registry.setColdWallet(address(0x1001));

        vm.expectRevert(IAutomationRegistry.InsufficientBalance.selector);

        vm.prank(admin);
        registry.withdrawFees(1 ether);
    }

    /// @dev Test to ensure 'withdrawFees' reverts if request amount exceeds the locked balance.
    function testWithdrawFeesRevertsIfRequestExceedsLockedBalance() public {
        testRegister();

        // Set cold wallet
        vm.prank(admin);
        registry.setColdWallet(address(0x1001));

        vm.expectRevert(IAutomationRegistry.RequestExceedsLockedBalance.selector);

        vm.prank(admin);
        registry.withdrawFees(0.04 ether);
    }

    /// @dev Test to ensure 'withdrawFees' reverts if caller is not owner.
    function testWithdrawFeesRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        registry.withdrawFees(1 ether);
    }

    /// @dev Test to ensure 'withdrawFees' withdraws the requested amount and updates the balance.
    function testWithdrawFees() public {
        testRegister();

        // Set cold wallet
        address coldWallet = address(0x1001);
        vm.prank(admin);
        registry.setColdWallet(coldWallet);

        assertEq(erc20Supra.balanceOf(coldWallet), 0);
        assertEq(erc20Supra.balanceOf(address(registry)), 0.502 ether);

        vm.prank(admin);
        registry.withdrawFees(0.002 ether);

        assertEq(erc20Supra.balanceOf(coldWallet), 0.002 ether);
        assertEq(erc20Supra.balanceOf(address(registry)), 0.5 ether);
    }
    
    /// @dev Test to ensure 'withdrawFees' emits event 'RegistryFeeWithdrawn'.
    function testWithdrawFeesEmitsEvent() public {
        testRegister();

        // Set cold wallet
        address coldWallet = address(0x1001);
        vm.prank(admin);
        registry.setColdWallet(coldWallet);

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.RegistryFeeWithdrawn(coldWallet, 0.002 ether);

        vm.prank(admin);
        registry.withdrawFees(0.002 ether);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'register' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Helper function to return payload.
    /// @param _value Value to be sent along with transaction.
    /// @param _target Address of destination smart contract.
    function createPayload(uint128 _value, address _target) private pure returns (bytes memory) {
        LibRegistry.AccessListEntry[] memory accessList = new LibRegistry.AccessListEntry[](2);
        
        bytes32[] memory keys = new bytes32[](2); 
        keys[0] = bytes32(uint256(0));
        keys[1] = bytes32(uint256(1));

        accessList[0] = LibRegistry.AccessListEntry({
            addr: address(0x1111),
            storageKeys: keys
        });

        accessList[1] = LibRegistry.AccessListEntry({
            addr: address(0x2222),
            storageKeys: keys
        });

        bytes memory callData = abi.encodeCall(ERC20Supra.withdraw, 100);
        bytes memory payload = abi.encode(_value, _target, callData, accessList);

        return payload;   
    }

    /// @dev Test to ensure 'register' reverts if automation is not enabled.
    function testRegisterRevertsIfAutomationNotEnabled() public {
        testSetAutomationController();

        // Disable automation
        vm.prank(admin);
        registry.disableAutomation();
        
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.register(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            uint128(10 gwei),                   // gasPriceCap
            uint128(0.5 ether),                 // automationFeeCapForCycle
            0,                                  // priority
            0,                                  // task type
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'register' reverts if registration is disabled.
    function testRegisterRevertsIfRegistrationDisabled() public {
        // Disable registration
        vm.prank(admin);
        registry.disableRegistration();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationRegistry.RegistrationDisabled.selector);

        vm.prank(alice);
        registry.register(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            uint128(10 gwei),                   // gasPriceCap
            uint128(0.5 ether),                 // automationFeeCapForCycle
            0,                                  // priority
            0,                                  // task type
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'register' reverts if task type is not UST.
    function testRegisterRevertsIfTaskTypeNotUST() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));      

        vm.expectRevert(IAutomationRegistry.InvalidTaskType.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            1,                                  // Task type not UST
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if expiry time is equal to or less than registration time.
    function testRegisterRevertsIfInvalidExpiryTime() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationRegistry.InvalidExpiryTime.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp),        // Invalid expiryTime
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if task duration is greater than the task duration cap.
    function testRegisterRevertsIfInvalidTaskDuration() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationRegistry.InvalidTaskDuration.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 3601),     // Invalid task duration
            keccak256("txHash"),                
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if task expires before the next cycle.
    function testRegisterRevertsIfTaskExpiresBeforeNextCycle() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 
        
        vm.expectRevert(IAutomationRegistry.TaskExpiresBeforeNextCycle.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2000),     // Task expires before next cycle
            keccak256("txHash"),                
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if payload target address is zero.
    function testRegisterRevertsIfPayloadTargetZero() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(0));               // Invalid address: address(0)

        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),                
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if payload target address is EOA.
    function testRegisterRevertsIfPayloadTargetEoa() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, alice);                    // Invalid address: EOA address being passed

        vm.expectRevert(IAutomationRegistry.AddressCannotBeEOA.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),                
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if 0 is passed as max gas amount.
    function testRegisterRevertsIfMaxGasAmountZero() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationRegistry.InvalidMaxGasAmount.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(0),                         // maxGasAmount
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if 0 is passed as gas price cap.
    function testRegisterRevertsIfGasPriceCapZero() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationRegistry.InvalidGasPriceCap.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(0),                       // gasPriceCap         
            uint128(0.5 ether),
            0,
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if transaction hash is bytes32(0).
    function testRegisterRevertsIfInvalidTxHash() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationRegistry.InvalidTxHash.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            bytes32(0),                     // Invalid tx hash            
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if gas committed exceeds the registry max gas cap.
    function testRegisterRevertsIfGasCommittedExceedsMaxGasCap() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationRegistry.GasCommittedExceedsMaxGasCap.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(10_000_001),            // Gas exceeds max gas cap
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if automation fee cap is less than the estimated automation fee.
    function testRegisterRevertsIfAutomationFeeCapLessThanEstimated() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));  

        vm.expectRevert(IAutomationRegistry.InsufficientFeeCapForCycle.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0),                       // automationFeeCapForCycle
            0,
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' registers a UST.
    function testRegister() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 
        
        vm.startPrank(alice);
        erc20Supra.deposit{value: 5 ether}();
        erc20Supra.approve(address(registry), type(uint256).max);

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

        LibCommonUtils.TaskDetails memory taskMetadata = registry.getTaskDetails(0);
        assertTrue(registry.ifTaskExists(0));
        assertEq(registry.totalTasks(), 1);
        assertEq(registry.getNextTaskIndex(), 1);
        assertEq(registry.getGasCommittedForNextCycle(), 1_000_000);
        assertEq(registry.getTotalDepositedAutomationFees(), 0.5 ether);
        assertEq(erc20Supra.balanceOf(address(registry)), 0.002 ether + 0.5 ether);
        assertEq(erc20Supra.balanceOf(alice), 4.5 ether - 0.002 ether);

        assertEq(taskMetadata.maxGasAmount, 1_000_000);
        assertEq(taskMetadata.gasPriceCap, 10 gwei);
        assertEq(taskMetadata.automationFeeCapForCycle, 0.5 ether);
        assertEq(taskMetadata.lockedFeeForNextCycle, 0.5 ether);
        assertEq(taskMetadata.txHash, keccak256("txHash"));
        assertEq(taskMetadata.taskIndex, 0);
        assertEq(taskMetadata.registrationTime, uint64(block.timestamp));
        assertEq(taskMetadata.expiryTime, uint64(block.timestamp + 2250));
        assertEq(taskMetadata.priority, 0);
        assertEq(uint8(taskMetadata.taskType), 0);
        assertEq(uint8(taskMetadata.state), 0);
        assertEq(taskMetadata.owner, alice);
        assertEq(taskMetadata.payloadTx, payload);
        assertEq(taskMetadata.auxData, auxData);
    }

    /// @dev Test to ensure 'register' emits event 'TaskRegistered'.
    function testRegisterEmitsEvent() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 
        
        vm.startPrank(alice);
        erc20Supra.deposit{value: 5 ether}();
        erc20Supra.approve(address(registry), type(uint256).max);

        LibCommonUtils.TaskDetails memory taskMetadata = LibCommonUtils.TaskDetails(
            1_000_000,
            10 gwei,
            0.5 ether,
            0.5 ether,
            keccak256("txHash"),
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 2250),
            0,
            LibCommonUtils.TaskType.UST,
            LibCommonUtils.TaskState.PENDING,
            alice,
            payload,      
            auxData
        );

        vm.expectEmit(true, true, false, true);
        emit AutomationRegistry.TaskRegistered(0, alice, 0.002 ether, 0.5 ether, taskMetadata);

        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            0,
            auxData
        );
        vm.stopPrank();
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'registerSystemTask' :::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'registerSystemTask' reverts if automation is not enabled.
    function testRegisterSystemTaskRevertsIfAutomationNotEnabled() public {
        testSetAutomationController();
        
        vm.prank(admin);
        registry.disableAutomation();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            2,                                  // priority
            1,                                  // task type
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if registration is disabled.
    function testRegisterSystemTaskRevertsIfRegistrationDisabled() public {
        vm.prank(admin);
        registry.disableRegistration();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        vm.expectRevert(IAutomationRegistry.RegistrationDisabled.selector);

        vm.prank(alice);
        registry.registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            2,                                  // priority
            1,                                  // task type
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if caller is not authorized.
    function testRegisterSystemTaskRevertsIfUnauthorizedCaller() public {
        testSetAutomationController();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(alice);
        registry.registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            2,                                  // priority
            1,                                  // task type
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if task type is not GST.
    function testRegisterSystemTaskRevertsIfTaskTypeNotGST() public {
        testSetAutomationController();
        testGrantAuthorization();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        vm.expectRevert(IAutomationRegistry.InvalidTaskType.selector);

        vm.prank(bob);
        registry.registerSystemTask(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(1_000_000),
            2,
            0,                                  // Task type not GST
            auxData
        );
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if task duration is greater than system task duration cap.
    function testRegisterSystemTaskRevertsIfInvalidTaskDuration() public {
        testSetAutomationController();
        testGrantAuthorization();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationRegistry.InvalidTaskDuration.selector);

        vm.prank(bob);
        registry.registerSystemTask(
            payload,
            uint64(block.timestamp + 3601),     // Invalid task duration
            keccak256("txHash"),
            uint128(1_000_000), 
            2, 
            1, 
            auxData
        );   
    }
    
    /// @dev Test to ensure 'registerSystemTask' reverts if gas committed exceeds the system registry max gas cap.
    function testRegisterSystemTaskRevertsIfGasCommittedExceedsMaxGasCap() public {
        testSetAutomationController();
        testGrantAuthorization();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        vm.expectRevert(IAutomationRegistry.GasCommittedExceedsMaxGasCap.selector);

        vm.prank(bob);
        registry.registerSystemTask(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(5_000_001),                 // Gas exceeds max gas cap
            2,
            1,
            auxData
        );
    }

    /// @dev Test to ensure 'registerSystemTask' registers a GST.
    function testRegisterSystemTask() public {
        testSetAutomationController();
        testGrantAuthorization();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.prank(bob);
        registry.registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            2,                                  // priority
            1,                                  // task type
            auxData                             // aux data
        );
        
        LibCommonUtils.TaskDetails memory taskMetadata = registry.getTaskDetails(0);
        assertTrue(registry.ifTaskExists(0));
        assertTrue(registry.ifSysTaskExists(0));
        assertEq(registry.totalTasks(), 1);
        assertEq(registry.totalSystemTasks(), 1);
        assertEq(registry.getNextTaskIndex(), 1);
        assertEq(registry.getSystemGasCommittedForNextCycle(), 1_000_000);

        assertEq(taskMetadata.maxGasAmount, 1_000_000);
        assertEq(taskMetadata.gasPriceCap, 0);
        assertEq(taskMetadata.automationFeeCapForCycle, 0);
        assertEq(taskMetadata.lockedFeeForNextCycle, 0);
        assertEq(taskMetadata.txHash, keccak256("txHash"));
        assertEq(taskMetadata.taskIndex, 0);
        assertEq(taskMetadata.registrationTime, uint64(block.timestamp));
        assertEq(taskMetadata.expiryTime, uint64(block.timestamp + 2250));
        assertEq(taskMetadata.priority, 2);
        assertEq(uint8(taskMetadata.taskType), 1);
        assertEq(uint8(taskMetadata.state), 0);
        assertEq(taskMetadata.owner, bob);
        assertEq(taskMetadata.payloadTx, payload);
        assertEq(taskMetadata.auxData, auxData);
    }

    /// @dev Test to ensure 'registerSystemTask' emits event 'SystemTaskRegistered'.
    function testRegisterSystemTaskEmitsEvent() public {
        testSetAutomationController();
        testGrantAuthorization();
        
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        LibCommonUtils.TaskDetails memory taskMetadata = LibCommonUtils.TaskDetails(
            1_000_000,
            0,
            0,
            0,
            keccak256("txHash"),
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 2250),
            2,
            LibCommonUtils.TaskType.GST,
            LibCommonUtils.TaskState.PENDING,
            bob,
            payload,      
            auxData
        );

        vm.expectEmit(true, true, false, true);
        emit AutomationRegistry.SystemTaskRegistered(0, bob, block.timestamp, taskMetadata);

        vm.prank(bob);
        registry.registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            2,                                  // priority
            1,                                  // task type
            auxData                             // aux data
        );
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'cancelTask' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'cancelTask' reverts if automation is not enabled.
    function testCancelTaskRevertsIfAutomationNotEnabled() public {
        testSetAutomationController();

        vm.prank(admin);
        registry.disableAutomation();
        
        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.cancelTask(0);
    }

    /// @dev Test to ensure 'cancelTask' reverts if task does not exist.
    function testCancelTaskRevertsIfTaskDoesNotExist() public {
        testSetAutomationController();

        vm.expectRevert(IAutomationRegistry.TaskDoesNotExist.selector);

        vm.prank(alice);
        registry.cancelTask(0);
    }

    /// @dev Test to ensure 'cancelTask' reverts if task type is not UST.
    function testCancelTaskRevertsIfTaskTypeNotUST() public {
        testSetAutomationController();

        testRegisterSystemTask();
        vm.expectRevert(IAutomationRegistry.UnsupportedTaskOperation.selector);

        vm.prank(bob);
        registry.cancelTask(0);
    }

    /// @dev Test to ensure 'cancelTask' reverts if caller is not the task owner.
    function testCancelTaskRevertsIfUnauthorizedCaller() public {
        testSetAutomationController();

        testRegister();
        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(bob);
        registry.cancelTask(0);
    }

    /// @dev Test to ensure 'cancelTask' cancels a UST.
    function testCancelTask() public {
        testSetAutomationController();
        testRegister();

        vm.prank(alice);
        registry.cancelTask(0);

        assertFalse(registry.ifTaskExists(0));
        assertEq(registry.totalTasks(), 0);
        assertEq(registry.getGasCommittedForNextCycle(), 0);
        assertEq(registry.getTotalDepositedAutomationFees(), 0);
        assertEq(erc20Supra.balanceOf(address(registry)), 0.002 ether + 0.25 ether);
        assertEq(erc20Supra.balanceOf(alice), 4.75 ether - 0.002 ether);
    }

    /// @dev Test to ensure 'cancelTask' emits event 'TaskCancelled'.
    function testCancelTaskEmitsEvent() public {
        testSetAutomationController();
        testRegister();
        
        vm.expectEmit(true, true, true, false);
        emit AutomationRegistry.TaskCancelled(0, alice, keccak256("txHash"));

        vm.prank(alice);
        registry.cancelTask(0);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'cancelSystemTask' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'cancelSystemTask' reverts if automation is not enabled. 
    function testCancelSystemTaskRevertsIfAutomationNotEnabled() public {
        testSetAutomationController();
        
        vm.prank(admin);
        registry.disableAutomation();
        
        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.cancelSystemTask(0);
    }

    /// @dev Test to ensure 'cancelSystemTask' reverts if task does not exist. 
    function testCancelSystemTaskRevertsIfTaskDoesNotExist() public {
        testSetAutomationController();

        vm.expectRevert(IAutomationRegistry.TaskDoesNotExist.selector);

        vm.prank(alice);
        registry.cancelSystemTask(0);
    }

    /// @dev Test to ensure 'cancelSystemTask' reverts if task does not exist in system tasks. 
    function testCancelSystemTaskRevertsIfSystemTaskDoesNotExist() public {
        testSetAutomationController();

        testRegister();
        vm.expectRevert(IAutomationRegistry.SystemTaskDoesNotExist.selector);

        vm.prank(alice);
        registry.cancelSystemTask(0);
    }

    /// @dev Test to ensure 'cancelSystemTask' reverts if caller is not the task owner. 
    function testCancelSystemTaskRevertsIfUnauthorizedCaller() public {
        testSetAutomationController();

        testRegisterSystemTask();
        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(alice);
        registry.cancelSystemTask(0);
    }
    /// @dev Test to ensure 'cancelSystemTask' cancels a GST. 
    function testCancelSystemTask() public {
        testSetAutomationController();
        testRegisterSystemTask();

        vm.prank(bob);
        registry.cancelSystemTask(0);
    
        assertFalse(registry.ifTaskExists(0));
        assertFalse(registry.ifSysTaskExists(0));
        assertEq(registry.totalTasks(), 0);
        assertEq(registry.totalSystemTasks(), 0);
        assertEq(registry.getSystemGasCommittedForNextCycle(), 0);
    }

    /// @dev Test to ensure 'cancelSystemTask' emits event 'TaskCancelled'. 
    function testCancelSystemTaskEmitsEvent() public {
        testSetAutomationController();
        testRegisterSystemTask();

        vm.expectEmit(true, true, true, false);
        emit AutomationRegistry.TaskCancelled(0, bob, keccak256("txHash"));

        vm.prank(bob);
        registry.cancelSystemTask(0);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'stopTasks' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'stopTasks' reverts if automation is not enabled. 
    function testStopTasksRevertsIfAutomationNotEnabled() public {
        testSetAutomationController();
        
        vm.prank(admin);
        registry.disableAutomation();
        
        uint64[] memory taskIndexes;
        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.stopTasks(taskIndexes);
    }
    
    /// @dev Test to ensure 'stopTasks' reverts if input array is empty. 
    function testStopTasksRevertsIfInputArrayEmpty() public {
        testSetAutomationController();

        uint64[] memory taskIndexes;
        vm.expectRevert(IAutomationRegistry.TaskIndexesCannotBeEmpty.selector);

        vm.prank(alice);
        registry.stopTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopTasks' reverts if caller is not the task owner. 
    function testStopTasksRevertsIfUnauthorizedCaller() public {
        testSetAutomationController();
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(bob);
        registry.stopTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopTasks' reverts if task type is not UST. 
    function testStopTasksRevertsIfTaskTypeNotUST() public {
        testSetAutomationController();
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IAutomationRegistry.UnsupportedTaskOperation.selector);

        vm.prank(bob);
        registry.stopTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopTasks' does nothing if task does not exist. 
    function testStopTasksDoesNothingIfTaskDoesNotExist() public {
        testSetAutomationController();
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 5;

        vm.prank(alice);
        registry.stopTasks(taskIndexes);

        assertEq(registry.totalTasks(), 1);
        assertEq(registry.getTotalDepositedAutomationFees(), 0.5 ether);
    }

    /// @dev Test to ensure 'stopTasks' stops the input UST tasks. 
    function testStopTasks() public {
        testSetAutomationController();
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.prank(alice);
        registry.stopTasks(taskIndexes);

        assertFalse(registry.ifTaskExists(0));
        assertEq(registry.totalTasks(), 0);
        assertEq(registry.getGasCommittedForNextCycle(), 0);
        assertEq(registry.getTotalDepositedAutomationFees(), 0);
        assertEq(erc20Supra.balanceOf(address(registry)), 0.002 ether + 0.25 ether);
        assertEq(erc20Supra.balanceOf(alice), 4.75 ether - 0.002 ether);
    }

    /// @dev Test to ensure 'stopTasks' emits event 'TasksStopped'.  
    function testStopTasksEmitsEvent() public {
        testSetAutomationController();
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        LibRegistry.TaskStopped[] memory stoppedTasks = new LibRegistry.TaskStopped[](1);
        stoppedTasks[0] = LibRegistry.TaskStopped(0, 0.25 ether, 0, keccak256("txHash"));

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.TasksStopped(stoppedTasks, alice);

        vm.prank(alice);
        registry.stopTasks(taskIndexes);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'stopSystemTasks' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'stopSystemTasks' reverts if automation is not enabled.
    function testStopSystemTasksRevertsIfAutomationNotEnabled() public {
        testSetAutomationController();

        vm.prank(admin);
        registry.disableAutomation();
        
        uint64[] memory taskIndexes;
        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' reverts if input array is empty.
    function testStopSystemTasksRevertsIfInputArrayEmpty() public {
        testSetAutomationController();

        uint64[] memory taskIndexes;
        vm.expectRevert(IAutomationRegistry.TaskIndexesCannotBeEmpty.selector);

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' reverts if caller is not the task owner.
    function testStopSystemTasksRevertsIfUnauthorizedCaller() public {
        testSetAutomationController();
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' reverts if task type is not GST.
    function testStopSystemTasksRevertsIfTaskTypeNotGST() public {
        testSetAutomationController();
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IAutomationRegistry.UnsupportedTaskOperation.selector);

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' does nothing if task does not exist.
    function testStopSystemTasksDoesNothingIfTaskDoesNotExist() public {
        testSetAutomationController();
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 5;

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);

        assertEq(registry.totalTasks(), 1);
        assertEq(registry.totalSystemTasks(), 1);
    }

    /// @dev Test to ensure 'stopSystemTasks' stops the input GST tasks.
    function testStopSystemTasks() public {
        testSetAutomationController();
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.prank(bob);
        registry.stopSystemTasks(taskIndexes);

        assertFalse(registry.ifTaskExists(0));
        assertFalse(registry.ifSysTaskExists(0));
        assertEq(registry.totalTasks(), 0);
        assertEq(registry.totalSystemTasks(), 0);
        assertEq(registry.getSystemGasCommittedForNextCycle(), 0);
    }

    /// @dev Test to ensure 'stopSystemTasks' emits event 'TasksStopped'.
    function testStopSystemTasksEmitsEvent() public {
        testSetAutomationController();
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        LibRegistry.TaskStopped[] memory stoppedTasks = new LibRegistry.TaskStopped[](1);
        stoppedTasks[0] = LibRegistry.TaskStopped(0, 0, 0, keccak256("txHash"));

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.TasksStopped(stoppedTasks, bob);

        vm.prank(bob);
        registry.stopSystemTasks(taskIndexes);
    }
}