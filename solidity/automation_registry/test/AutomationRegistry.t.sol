// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {AutomationRegistry} from "../src/AutomationRegistry.sol";
import {AutomationController} from "../src/AutomationController.sol";
import {IAutomationRegistry} from "../src/IAutomationRegistry.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {BlockMeta} from "../src/BlockMeta.sol";
import {LibRegistry} from "../src/LibRegistry.sol";
import {CommonUtils} from "../src/CommonUtils.sol";

contract AutomationRegistryTest is Test {
    AutomationRegistry impl;                    // implementation logic contract
    AutomationRegistry registry;                // registry instance on proxy address
    ERC1967Proxy proxy;                         // proxy contract
    ERC20Supra supraERC20;                      // ERC20Supra contract

    address admin = address(0xA11CE);
    address vmAddress = address(0x99);
    address alice = address(0x123);
    address bob = address(0x456);

    function setUp() public {
        vm.deal(alice, 100 ether);

        vm.startPrank(admin);
        supraERC20 = new ERC20Supra(msg.sender);
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
                vmAddress,                  // vm address
                address(supraERC20)         // supraERC20 address
            )
        );

        proxy = new ERC1967Proxy(address(impl), initData);
        registry = AutomationRegistry(address(proxy));
        vm.stopPrank();
    }

    function testInitialize() public view {
        assertEq(registry.getNextCycleRegistryMaxGasCap(), 10_000_000);
        assertEq(registry.getNextCycleSysRegistryMaxGasCap(), 5_000_000);
        assertEq(registry.getAutomationController(), address(0));
        assertTrue(registry.isRegistrationEnabled());
        assertTrue(registry.isAutomationEnabled());
        assertEq(registry.getVM(), vmAddress);
        assertEq(registry.supraERC20(), address(supraERC20));

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

    function testInitializeRevertsIfReinitialized() public {
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
    
        registry.initialize(
            3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2,
            500, 2000, 3600, 5_000_000, 500,
            vmAddress, address(supraERC20)
        );
    }

    function testInitializeRevertsIfVmAddressZero() public {
        AutomationRegistry implementation = new AutomationRegistry();

        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2,
                500, 2000, 3600, 5_000_000, 500,
                address(0),                             // VM address as zero
                address(supraERC20)
            )
        );

        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function testInitializeRevertsIfSupraERC20IsEoa() public {
        AutomationRegistry implementation = new AutomationRegistry();

        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2,
                500, 2000, 3600, 5_000_000, 500,
                vmAddress, 
                admin                                   // EOA address as ERC20Supra
            )
        );

        vm.expectRevert(IAutomationRegistry.AddressCannotBeEOA.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function testInitializeRevertsIfInvalidTaskCapacity() public {
        AutomationRegistry implementation = new AutomationRegistry();

        bytes memory initData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2,
                0,                                      // 0 as task capacity 
                2000, 3600, 5_000_000, 500,
                vmAddress, address(supraERC20)
            )
        );

        vm.expectRevert(IAutomationRegistry.InvalidTaskCapacity.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Registration Enabled ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    function testDisableRegistration() public {
        vm.prank(admin);
        registry.disableRegistration();

        assertFalse(registry.isRegistrationEnabled());
    }

    function testDisableRegistrationEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit AutomationRegistry.TaskRegistrationDisabled(false);

        testDisableRegistration();
    }

    function testDisableRegistrationRevertsIfAlreadyDisabled() public {
        // First disable
        testDisableRegistration();

        // Disable again → revert
        vm.expectRevert(IAutomationRegistry.AlreadyDisabled.selector);

        vm.prank(admin);
        registry.disableRegistration();
    }

    function testDisableRegistrationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        
        vm.prank(alice);
        registry.disableRegistration();
    }

    function testEnableRegistration() public {
        // Disable registration
        testDisableRegistration();

        // Enable registration
        vm.prank(admin);
        registry.enableRegistration();

        assertTrue(registry.isRegistrationEnabled());
    }

    function testEnableRegistrationEmitsEvent() public {
        // Disable registration
        testDisableRegistration();

        vm.expectEmit(true, false, false, false);
        emit AutomationRegistry.TaskRegistrationEnabled(true);

        // Enable registration
        vm.prank(admin);
        registry.enableRegistration();
    }

    function testEnableRegistrationRevertsIfAlreadyEnabled() public {
        // Already enabled in initialize()
        vm.expectRevert(IAutomationRegistry.AlreadyEnabled.selector);

        vm.prank(admin);
        registry.enableRegistration();
    }

    function testEnableRegistrationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        
        vm.prank(alice);
        registry.enableRegistration();
    }
    
    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Automation Enabled ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    function testDisableAutomation() public {
        // Already enabled in initialize()
        vm.prank(admin);
        registry.disableAutomation();

        assertFalse(registry.isAutomationEnabled());
    }

    function testDisableAutomationEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit AutomationRegistry.AutomationDisabled(false);

        testDisableAutomation();
    }

    function testDisableAutomationRevertsIfAlreadyDisabled() public {
        // First disable
        testDisableAutomation();

        // Disable again → revert
        vm.expectRevert(IAutomationRegistry.AlreadyDisabled.selector);

        vm.prank(admin);
        registry.disableAutomation();
    }

    function testDisableAutomationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.disableAutomation();
    }

    function testEnableAutomation() public {
        // Disable automation
        testDisableAutomation();

        // Enable automation
        vm.prank(admin);
        registry.enableAutomation();

        assertTrue(registry.isAutomationEnabled());
    }

    function testEnableAutomationEmitsEvent() public {
        // First disable
        testDisableAutomation();

        vm.expectEmit(true, false, false, false);
        emit AutomationRegistry.AutomationEnabled(true);

        vm.prank(admin);
        registry.enableAutomation();
    }

    function testEnableAutomationRevertsIfAlreadyEnabled() public {
        // Already enabled in initialize()
        vm.expectRevert(IAutomationRegistry.AlreadyEnabled.selector);

        vm.prank(admin);
        registry.enableAutomation();
    }

    function testEnableAutomationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.enableAutomation();
    }


    // ::::::::::::::: Controller ::::::::::::::::::::

    function deployAutomationController() internal returns (address) {
        // Deploy BlockMeta proxy
        BlockMeta blockMetaImpl = new BlockMeta();
        bytes memory blockMetaInitData = abi.encodeCall(BlockMeta.initialize, ());
        ERC1967Proxy blockMetaProxy = new ERC1967Proxy(address(blockMetaImpl), blockMetaInitData);

        // Deploy AutomationController proxy
        AutomationController controllerImpl = new AutomationController();
        bytes memory controllerInitData = abi.encodeCall(AutomationController.initialize,(address(registry), address(blockMetaProxy)));
        ERC1967Proxy controllerProxy = new ERC1967Proxy(address(controllerImpl), controllerInitData);

        return address(controllerProxy);
    }

    function testSetAutomationController() public {
        address controller = deployAutomationController(); 
        
        vm.prank(admin);
        registry.setAutomationController(controller);

        assertEq(registry.getAutomationController(), controller);
    }

    function testSetAutomationControllerEmitsEvent() public {
        address oldController = registry.getAutomationController();
        address controller = deployAutomationController();

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.AutomationControllerUpdated(oldController, controller);

        vm.prank(admin);
        registry.setAutomationController(controller);
    }

    function testSetAutomationControllerRevertsIfNotOwner() public {
        address controller = deployAutomationController();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.setAutomationController(controller);
    }

    function testSetAutomationControllerRevertsIfZeroAddress() public {
        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);

        vm.prank(admin);
        registry.setAutomationController(address(0));
    }

    function testSetAutomationControllerRevertsIfEoa() public {
        vm.expectRevert(IAutomationRegistry.AddressCannotBeEOA.selector);

        vm.prank(admin);
        registry.setAutomationController(alice);
    }

    // Set VM address
    function testSetVm() public {
        address newVM = address(0x100);

        vm.prank(admin);
        registry.setVM(newVM);

        assertEq(registry.getVM(), newVM);
    }

    function testSetVmEmitsEvent() public {
        address oldVM = registry.getVM();
        address newVM = address(0x100);

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.VmAddressUpdated(oldVM, newVM);

        vm.prank(admin);
        registry.setVM(newVM);
    }

    function testSetVmRevertsIfZeroAddress() public {
        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);

        vm.prank(admin);
        registry.setVM(address(0));
    }

    function testSetVmRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        registry.setVM(address(0x100));
    }

    // Set ERC20Supra
    function testSetSupraERC20() public {
        ERC20Supra supra = new ERC20Supra(msg.sender);

        vm.prank(admin);
        registry.setSupraERC20(address(supra));

        assertEq(registry.supraERC20(), address(supra));
    }

    function testSetSupraERC20EmitsEvent() public {
        address oldAddr = registry.supraERC20();
        ERC20Supra supra = new ERC20Supra(msg.sender);

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.SupraERC20Updated(oldAddr, address(supra));

        vm.prank(admin);
        registry.setSupraERC20(address(supra));
    }

    function testSetSupraERC20RevertsIfZeroAddress() public {
        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);

        vm.prank(admin);
        registry.setSupraERC20(address(0));
    }

    function testSetSupraERC20RevertsIfEoa() public {
        vm.expectRevert(IAutomationRegistry.AddressCannotBeEOA.selector);

        vm.prank(admin);
        registry.setSupraERC20(alice);
    }

    function testSetSupraERC20RevertsIfNotOwner() public {
        ERC20Supra supra = new ERC20Supra(msg.sender);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        registry.setSupraERC20(address(supra));
    }

    // Cold wallet
    function testSetColdWallet() public {
        vm.prank(admin);
        registry.setColdWallet(address(0x1001));

        assertEq(registry.getColdWallet(), address(0x1001));
    }

    function testSetColdWalletEmitsEvent() public {
        address oldColdWallet = registry.getColdWallet();
    
        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.ColdWalletUpdated(oldColdWallet, address(0x1001));
    
        vm.prank(admin);
        registry.setColdWallet(address(0x1001));
    }

    function testSetColdWalletRevertsIfZeroAddress() public {
        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);

        vm.prank(admin);
        registry.setColdWallet(address(0));
    }

    function testSetColdWalletRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        registry.setColdWallet(address(0x1001));
    }

    // Grant Authorization
    function testGrantAuthorization() public {
        vm.prank(admin);
        registry.grantAuthorization(bob);

        assertTrue(registry.isAuthorizedSubmitter(bob));
    }

    function testGrantAuthorizationEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.AuthorizationGranted(bob, block.timestamp);

        vm.prank(admin);
        registry.grantAuthorization(bob);
    }

    function testGrantAuthorizationRevertsIfExists() public {
        // Grant authorization to bob
        testGrantAuthorization();

        vm.expectRevert(IAutomationRegistry.AddressAlreadyExists.selector);

        vm.prank(admin);
        registry.grantAuthorization(bob);
    }

    function testGrantAuthorizationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.grantAuthorization(bob);
    }

    // Revoke Authorization
    function testRevokeAuthorization() public {
        // Grant authorization to bob
        testGrantAuthorization();

        // Revoke authorization
        vm.prank(admin);
        registry.revokeAuthorization(bob);

        assertFalse(registry.isAuthorizedSubmitter(bob));
    }

    function testRevokeAuthorizationEmitsEvent() public {
        // Grant authorization to bob
        testGrantAuthorization();

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.AuthorizationRevoked(bob, block.timestamp);

        vm.prank(admin);
        registry.revokeAuthorization(bob);
    }

    function testRevokeAuthorizationRevertsIfNotExists() public {
        vm.expectRevert(IAutomationRegistry.AddressDoesNotExist.selector);

        vm.prank(admin);
        registry.revokeAuthorization(bob);
    }

    function testRevokeAuthorizationRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.revokeAuthorization(bob);
    }

    // Update config
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

    function testUpdateConfig() public {
        LibRegistry.ConfigDetails memory cfg = validConfig();
    
        vm.prank(admin);
        registry.updateConfig(
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
    
        // Buffer should be updated
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

    function testUpdateConfigEmitsEvent() public {
        LibRegistry.ConfigDetails memory cfg = validConfig();

        vm.expectEmit(true, false, false, false);
        emit AutomationRegistry.ConfigBufferUpdated(cfg);
        
        vm.prank(admin);
        registry.updateConfig(
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

    function testUpdateConfigRevertsIfNotOwner() public {
        LibRegistry.ConfigDetails memory cfg = validConfig();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.updateConfig(
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

    // Withdraw Automation Task Fees
    function testWithdrawAutomationFeesRevertsIfColdWalletNotSet() public {
        vm.prank(admin);

        vm.expectRevert(IAutomationRegistry.ColdWalletNotSet.selector);
        registry.withdrawAutomationTaskFees(1 ether);
    }

    function testWithdrawAutomationFeesRevertsIfInsufficientBalance() public {
        // Set cold wallet
        vm.prank(admin);
        registry.setColdWallet(address(0x1001));

        vm.expectRevert(IAutomationRegistry.InsufficientBalance.selector);

        vm.prank(admin);
        registry.withdrawAutomationTaskFees(1 ether);
    }

    function testWithdrawAutomationFeesRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        registry.withdrawAutomationTaskFees(1 ether);
    }

    // Register
    function payloadAndAuxData(uint8 _type) internal returns (bytes memory, bytes[] memory) {
        ERC20Supra target = new ERC20Supra(alice);
        bytes memory callData = abi.encodeCall(ERC20Supra.withdraw, 100);
        bytes memory payload = abi.encode(address(target), callData);

        bytes[] memory auxData = new bytes[](2);
        auxData[0] = abi.encode(uint8(_type));
        auxData[1] = abi.encode(uint64(100));

        return (payload, auxData);   
    }

    function testRegisterRevertAutomationNotEnabled() public {
        vm.prank(admin);
        registry.disableAutomation();
        
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0);

        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.register(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            uint128(10 gwei),                   // gasPriceCap
            uint128(0.5 ether),                 // automationFeeCapForCycle
            auxData                             // aux data
        );
    }

    function testRegisterRevertRegistrationDisabled() public {
        vm.prank(admin);
        registry.disableRegistration();
        
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0);

        vm.expectRevert(IAutomationRegistry.RegistrationDisabled.selector);

        vm.prank(alice);
        registry.register(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            uint128(10 gwei),                   // gasPriceCap
            uint128(0.5 ether),                 // automationFeeCapForCycle
            auxData                             // aux data
        );
    }

    function testRegisterRevertInvalidMaxGasAmount() public {
        testSetAutomationController();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0); 

        vm.expectRevert(IAutomationRegistry.InvalidMaxGasAmount.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(0),                         // maxGasAmount = 0
            uint128(10 gwei),
            uint128(0.5 ether),
            auxData
        );
    }

    function testRegisterRevertInvalidGasPriceCap() public {
        testSetAutomationController();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0); 

        vm.expectRevert(IAutomationRegistry.InvalidGasPriceCap.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(0),                       // gasPriceCap = 0           
            uint128(0.5 ether),
            auxData
        );
    }

    function testRegisterRevertInvalidAutomationFeeCapForCycle() public {
        testSetAutomationController();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0); 

        vm.expectRevert(IAutomationRegistry.InsufficientFeeCapForCycle.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0),                       // automationFeeCapForCycle = 0
            auxData
        );
    }

    function testRegisterRevertInvalidExpiryTime() public {
        testSetAutomationController();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0); 

        vm.expectRevert(IAutomationRegistry.InvalidExpiryTime.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp),        // invalid expiryTime
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            auxData
        );
    }

    function testRegisterRevertInvalidAuxDataLength() public {
        testSetAutomationController();

        ERC20Supra target = new ERC20Supra(alice);
        bytes memory callData = abi.encodeCall(ERC20Supra.withdraw, 100);
        bytes memory payload = abi.encode(address(target), callData);

        bytes[] memory auxData = new bytes[](3);    // Invalid length
        auxData[0] = abi.encode(uint8(0));

        vm.expectRevert(IAutomationRegistry.InvalidAuxDataLength.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            auxData
        );
    }

    function testRegisterRevertInvalidTaskType() public {
        testSetAutomationController();

        ERC20Supra target = new ERC20Supra(alice);
        bytes memory callData = abi.encodeCall(ERC20Supra.withdraw, 100);
        bytes memory payload = abi.encode(address(target), callData);

        bytes[] memory auxData = new bytes[](2);
        auxData[0] = abi.encode(uint8(1));        // Invalid task type: expected 0, passing 1

        vm.expectRevert(IAutomationRegistry.InvalidTaskType.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            auxData
        );
    }

    function testRegisterRevertInvalidTaskDuration() public {
        testSetAutomationController();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0); 

        vm.expectRevert(IAutomationRegistry.InvalidTaskDuration.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 3601),     // Invalid task duration
            keccak256("txHash"),                
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            auxData
        );
    }

    function testRegisterRevertTaskExpiresBeforeNextCycle() public {
        testSetAutomationController();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0); 
        
        vm.expectRevert(IAutomationRegistry.TaskExpiresBeforeNextCycle.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2000),     // Task expires before next cycle
            keccak256("txHash"),                
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            auxData
        );
    }

    function testRegisterRevertAddressCannotBeZero() public {
        testSetAutomationController();

        bytes memory callData = abi.encodeCall(ERC20Supra.withdraw, 100);
        bytes memory payload = abi.encode(address(0), callData);        // Invalid address: address(0)

        bytes[] memory auxData = new bytes[](2);
        auxData[0] = abi.encode(uint8(0));  

        vm.expectRevert(IAutomationRegistry.AddressCannotBeZero.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),                
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            auxData
        );
    }

    function testRegisterRevertAddressCannotBeEoa() public {
        testSetAutomationController();

        bytes memory callData = abi.encodeCall(ERC20Supra.withdraw, 100);
        bytes memory payload = abi.encode(alice, callData);        // Invalid address: EOA address being passed

        bytes[] memory auxData = new bytes[](2);
        auxData[0] = abi.encode(uint8(0));  

        vm.expectRevert(IAutomationRegistry.AddressCannotBeEOA.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),                
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            auxData
        );
    }

    function testRegisterRevertInvalidTxHash() public {
        testSetAutomationController();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0); 

        vm.expectRevert(IAutomationRegistry.InvalidTxHash.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            bytes32(0),                     // Invalid tx hash            
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            auxData
        );
    }

    function testRegisterRevertGasCommittedExceedsMaxGasCap() public {
        testSetAutomationController();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0); 

        vm.expectRevert(IAutomationRegistry.GasCommittedExceedsMaxGasCap.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(10_000_001),            // Gas exceeds max gas cap
            uint128(10 gwei),
            uint128(0.5 ether),
            auxData
        );
    }

    function testRegister() public {
        testSetAutomationController();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0); 
        
        vm.startPrank(alice);
        supraERC20.deposit{value: 5 ether}();
        supraERC20.approve(address(registry), type(uint256).max);

        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            auxData
        );
        vm.stopPrank();

        CommonUtils.TaskDetails memory taskMetadata = registry.getTaskDetails(0);
        assertTrue(registry.ifTaskExists(0));
        assertEq(registry.totalTasks(), 1);
        assertEq(registry.getNextTaskIndex(), 1);
        assertEq(registry.getGasCommittedForNextCycle(), 1_000_000);
        assertEq(registry.getTotalDepositedAutomationFees(), 0.5 ether);
        assertEq(supraERC20.balanceOf(address(registry)), 0.002 ether + 0.5 ether);
        assertEq(supraERC20.balanceOf(alice), 4.5 ether - 0.002 ether);

        assertEq(taskMetadata.maxGasAmount, 1_000_000);
        assertEq(taskMetadata.gasPriceCap, 10 gwei);
        assertEq(taskMetadata.automationFeeCapForCycle, 0.5 ether);
        assertEq(taskMetadata.lockedFeeForNextCycle, 0.5 ether);
        assertEq(taskMetadata.txHash, keccak256("txHash"));
        assertEq(taskMetadata.taskIndex, 0);
        assertEq(taskMetadata.registrationTime, uint64(block.timestamp));
        assertEq(taskMetadata.expiryTime, uint64(block.timestamp + 2250));
        assertEq(taskMetadata.owner, alice);
        assertEq(uint8(taskMetadata.state), 0);
        assertEq(taskMetadata.payloadTx, payload);
        assertEq(taskMetadata.auxData, auxData);
    }

    function testRegisterEmitsEvent() public {
        testSetAutomationController();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0); 
        
        vm.startPrank(alice);
        supraERC20.deposit{value: 5 ether}();
        supraERC20.approve(address(registry), type(uint256).max);

        CommonUtils.TaskDetails memory taskMetadata = CommonUtils.TaskDetails(
            1_000_000,
            10 gwei,
            0.5 ether,
            0.5 ether,
            keccak256("txHash"),
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 2250),
            alice,
            CommonUtils.TaskState.PENDING,
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
            auxData
        );
        vm.stopPrank();
    }

    // Register system task
    function testRegisterSystemTaskRevertAutomationNotEnabled() public {
        vm.prank(admin);
        registry.disableAutomation();
        
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(1);

        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            auxData                             // aux data
        );
    }

    function testRegisterSystemTaskRevertRegistrationDisabled() public {
        vm.prank(admin);
        registry.disableRegistration();
        
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(1);

        vm.expectRevert(IAutomationRegistry.RegistrationDisabled.selector);

        vm.prank(alice);
        registry.registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            auxData                             // aux data
        );
    }

    function testRegisterSystemTaskRevertUnauthorizedAccount() public {
        testSetAutomationController();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(1);

        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(alice);
        registry.registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            auxData                             // aux data
        );
    }
    
    function testRegisterSystemTaskRevertInvalidAuxDataLength() public {
        testSetAutomationController();
        testGrantAuthorization();

        ERC20Supra target = new ERC20Supra(alice);
        bytes memory callData = abi.encodeCall(ERC20Supra.withdraw, 100);
        bytes memory payload = abi.encode(address(target), callData);

        bytes[] memory auxData = new bytes[](3);
        auxData[0] = abi.encode(uint8(1));
        auxData[1] = abi.encode(uint64(100));

        vm.expectRevert(IAutomationRegistry.InvalidAuxDataLength.selector);

        vm.prank(bob);
        registry.registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            auxData                             // aux data
        );
    }

    function testRegisterSystemTaskRevertInvalidTaskType() public {
        testSetAutomationController();
        testGrantAuthorization();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(0);

        vm.expectRevert(IAutomationRegistry.InvalidTaskType.selector);

        vm.prank(bob);
        registry.registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            auxData                             // aux data
        );
    }

    function testRegisterSystemTask() public {
        testSetAutomationController();
        testGrantAuthorization();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(1);

        vm.prank(bob);
        registry.registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            keccak256("txHash"),                // txHash
            uint128(1_000_000),                 // maxGasAmount
            auxData                             // aux data
        );
        
        CommonUtils.TaskDetails memory taskMetadata = registry.getTaskDetails(0);
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
        assertEq(taskMetadata.owner, bob);
        assertEq(uint8(taskMetadata.state), 0);
        assertEq(taskMetadata.payloadTx, payload);
        assertEq(taskMetadata.auxData, auxData);
    }

    function testRegisterSystemTaskEmitsEvent() public {
        testSetAutomationController();
        testGrantAuthorization();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(1);

        CommonUtils.TaskDetails memory taskMetadata = CommonUtils.TaskDetails(
            1_000_000,
            0,
            0,
            0,
            keccak256("txHash"),
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 2250),
            bob,
            CommonUtils.TaskState.PENDING,
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
            auxData                             // aux data
        );
    }

    function testRegisterSystemTaskRevertGasCommittedExceedsMaxGasCap() public {
        testSetAutomationController();
        testGrantAuthorization();
        (bytes memory payload, bytes[] memory auxData) = payloadAndAuxData(1);

        vm.expectRevert(IAutomationRegistry.GasCommittedExceedsMaxGasCap.selector);

        vm.prank(bob);
        registry.registerSystemTask(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(5_000_001),                 // Gas exceeds max gas cap
            auxData
        );
    }

    // Cancel task
    function testCancelTaskRevertAutomationNotEnabled() public {
        vm.prank(admin);
        registry.disableAutomation();
        
        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.cancelTask(0);
    }

    function testCancelTaskRevertTaskDoesNotExist() public {
        testSetAutomationController();

        vm.expectRevert(IAutomationRegistry.TaskDoesNotExist.selector);

        vm.prank(alice);
        registry.cancelTask(0);
    }

    function testCancelTaskRevertUnsupportedTaskOperation() public {
        testSetAutomationController();

        testRegisterSystemTask();
        vm.expectRevert(IAutomationRegistry.UnsupportedTaskOperation.selector);

        vm.prank(bob);
        registry.cancelTask(0);
    }

    function testCancelTaskRevertUnauthorizedAccount() public {
        testSetAutomationController();

        testRegister();
        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(bob);
        registry.cancelTask(0);
    }

    function testCancelTask() public {
        testSetAutomationController();
        testRegister();

        vm.prank(alice);
        registry.cancelTask(0);

        assertFalse(registry.ifTaskExists(0));
        assertEq(registry.totalTasks(), 0);
        assertEq(registry.getGasCommittedForNextCycle(), 0);
        assertEq(registry.getTotalDepositedAutomationFees(), 0);
        assertEq(supraERC20.balanceOf(address(registry)), 0.002 ether + 0.25 ether);
        assertEq(supraERC20.balanceOf(alice), 4.75 ether - 0.002 ether);
    }

    function testCancelTaskEmitsEvent() public {
        testSetAutomationController();
        testRegister();
        
        vm.expectEmit(true, true, true, false);
        emit AutomationRegistry.TaskCancelled(0, alice, keccak256("txHash"));

        vm.prank(alice);
        registry.cancelTask(0);
    }

    // Cancel system task
    function testCancelSystemTaskRevertAutomationNotEnabled() public {
        vm.prank(admin);
        registry.disableAutomation();
        
        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.cancelSystemTask(0);
    }

    function testCancelSystemTaskRevertTaskDoesNotExist() public {
        testSetAutomationController();

        vm.expectRevert(IAutomationRegistry.TaskDoesNotExist.selector);

        vm.prank(alice);
        registry.cancelSystemTask(0);
    }

    function testCancelSystemTaskRevertSystemTaskDoesNotExist() public {
        testSetAutomationController();

        testRegister();
        vm.expectRevert(IAutomationRegistry.SystemTaskDoesNotExist.selector);

        vm.prank(alice);
        registry.cancelSystemTask(0);
    }

    function testCancelSystemTaskRevertUnauthorizedAccount() public {
        testSetAutomationController();

        testRegisterSystemTask();
        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(alice);
        registry.cancelSystemTask(0);
    }

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

    function testCancelSystemTaskEmitsEvent() public {
        testSetAutomationController();
        testRegisterSystemTask();

        vm.expectEmit(true, true, true, false);
        emit AutomationRegistry.TaskCancelled(0, bob, keccak256("txHash"));

        vm.prank(bob);
        registry.cancelSystemTask(0);
    }

    // Stop tasks
    function testStopTasksRevertAutomationNotEnabled() public {
        vm.prank(admin);
        registry.disableAutomation();
        
        uint64[] memory taskIndexes;
        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.stopTasks(taskIndexes);
    }
    
    function testStopTasksRevertTaskIndexesCannotBeEmpty() public {
        testSetAutomationController();

        uint64[] memory taskIndexes;
        vm.expectRevert(IAutomationRegistry.TaskIndexesCannotBeEmpty.selector);

        vm.prank(alice);
        registry.stopTasks(taskIndexes);
    }

    function testStopTasksRevertUnauthorizedAccount() public {
        testSetAutomationController();
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(bob);
        registry.stopTasks(taskIndexes);
    }

    function testStopTasksRevertUnsupportedTaskOperation() public {
        testSetAutomationController();
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IAutomationRegistry.UnsupportedTaskOperation.selector);

        vm.prank(bob);
        registry.stopTasks(taskIndexes);
    }

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
        assertEq(supraERC20.balanceOf(address(registry)), 0.002 ether + 0.25 ether);
        assertEq(supraERC20.balanceOf(alice), 4.75 ether - 0.002 ether);
    }

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

    // Stop system tasks
    function testStopSystemTasksRevertAutomationNotEnabled() public {
        vm.prank(admin);
        registry.disableAutomation();
        
        uint64[] memory taskIndexes;
        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);
    }

    function testStopSystemTasksRevertTaskIndexesCannotBeEmpty() public {
        testSetAutomationController();

        uint64[] memory taskIndexes;
        vm.expectRevert(IAutomationRegistry.TaskIndexesCannotBeEmpty.selector);

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);
    }

    function testStopSystemTasksRevertUnauthorizedAccount() public {
        testSetAutomationController();
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);
    }

    function testStopSystemTasksRevertUnsupportedTaskOperation() public {
        testSetAutomationController();
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IAutomationRegistry.UnsupportedTaskOperation.selector);

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);
    }

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