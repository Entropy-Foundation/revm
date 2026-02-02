// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {AutomationRegistry} from "../src/AutomationRegistry.sol";
import {AutomationCore} from "../src/AutomationCore.sol";
import {AutomationController} from "../src/AutomationController.sol";
import {IAutomationCore} from "../src/IAutomationCore.sol";
import {IAutomationRegistry} from "../src/IAutomationRegistry.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {LibConfig} from "../src/LibConfig.sol";
import {LibRegistry} from "../src/LibRegistry.sol";
import {CommonUtils} from "../src/CommonUtils.sol";

contract AutomationRegistryTest is Test {
    ERC20Supra erc20Supra;                      // ERC20Supra contract
    AutomationCore automationCore;              // AutomationCore instance on proxy address
    AutomationRegistry registry;                // AutomationRegistry instance on proxy address
    address controller;                         // AutomationController proxy address

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

        AutomationController controllerImpl = new AutomationController();
        bytes memory controllerInitData = abi.encodeCall(AutomationController.initialize,(address(automationCore), address(registry)));
        ERC1967Proxy controllerProxy = new ERC1967Proxy(address(controllerImpl), controllerInitData);
        controller = address(controllerProxy);

        automationCore.setAutomationRegistry(address(registry));
        automationCore.setAutomationController(controller);

        registry.setAutomationController(controller);

        vm.stopPrank();
    }

    /// @dev Test to ensure all state variables are initialized correctly.
    function testInitialize() public view {
        assertEq(registry.owner(), admin);
        assertEq(registry.automationCore(), address(automationCore));
        assertEq(registry.automationController(), controller);
    }

    /// @dev Test to ensure reinitialization fails.
    function testInitializeRevertsIfReinitialized() public {
        AutomationCore automationCoreImplementation = new AutomationCore();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        
        vm.prank(admin);    
        registry.initialize(address(automationCoreImplementation));
    }

    /// @dev Test to ensure initialization fails if AutomationCore address is zero.
    function testInitializeRevertsIfAutomationCoreAddressIsZero() public {
        AutomationRegistry implementation = new AutomationRegistry();
        bytes memory initData = abi.encodeCall(AutomationRegistry.initialize, (address(0)));

        vm.expectRevert(CommonUtils.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(implementation), initData);
    }
  
    /// @dev Test to ensure initialization fails if EOA is passed as AutomationCore address.
    function testInitializeRevertsIfAutomationCoreAddressIsEoa() public {
        AutomationRegistry implementation = new AutomationRegistry();
        bytes memory initData = abi.encodeCall(AutomationRegistry.initialize, (admin));

        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);
        new ERC1967Proxy(address(implementation), initData);
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
        address controllerAddr = deployAutomationController(); 
        
        vm.prank(admin);
        registry.setAutomationController(controllerAddr);

        assertEq(registry.automationController(), controllerAddr);
    }

    /// @dev Test to ensure 'setAutomationController' emits event 'AutomationControllerUpdated'.
    function testSetAutomationControllerEmitsEvent() public {
        address oldController = registry.automationController();
        address controllerAddr = deployAutomationController();

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.AutomationControllerUpdated(oldController, controllerAddr);

        vm.prank(admin);
        registry.setAutomationController(controllerAddr);
    }

    /// @dev Test to ensure 'setAutomationController' reverts if caller is not owner.
    function testSetAutomationControllerRevertsIfNotOwner() public {
        address controllerAddr = deployAutomationController();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        registry.setAutomationController(controllerAddr);
    }

    /// @dev Test to ensure 'setAutomationController' reverts if zero address is passed.
    function testSetAutomationControllerRevertsIfZeroAddress() public {
        vm.expectRevert(CommonUtils.AddressCannotBeZero.selector);

        vm.prank(admin);
        registry.setAutomationController(address(0));
    }

    /// @dev Test to ensure 'setAutomationController' reverts if EOA is passed.
    function testSetAutomationControllerRevertsIfEoa() public {
        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);

        vm.prank(admin);
        registry.setAutomationController(alice);
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

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'register' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Helper function to return payload.
    /// @param _value Value to be sent along with transaction.
    /// @param _target Address of destination smart contract.
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

    /// @dev Test to ensure 'register' reverts if automation is not enabled.
    function testRegisterRevertsIfAutomationNotEnabled() public {
        // Disable automation
        vm.prank(admin);
        automationCore.disableAutomation();
        
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
        automationCore.disableRegistration();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationCore.RegistrationDisabled.selector);

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
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));      

        vm.expectRevert(IAutomationCore.InvalidTaskType.selector);

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
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationCore.InvalidExpiryTime.selector);

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
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationCore.InvalidTaskDuration.selector);

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
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 
        
        vm.expectRevert(IAutomationCore.TaskExpiresBeforeNextCycle.selector);

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
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(0));               // Invalid address: address(0)

        vm.expectRevert(CommonUtils.AddressCannotBeZero.selector);

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
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, alice);                    // Invalid address: EOA address being passed

        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);

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
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationCore.InvalidMaxGasAmount.selector);

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
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationCore.InvalidGasPriceCap.selector);

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
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationCore.InvalidTxHash.selector);

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

    /// @dev Test to ensure 'register' reverts if automation fee cap is less than the estimated automation fee.
    function testRegisterRevertsIfAutomationFeeCapLessThanEstimated() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));  

        vm.expectRevert(IAutomationCore.InsufficientFeeCapForCycle.selector);

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

    /// @dev Test to ensure 'register' reverts if gas committed exceeds the registry max gas cap.
    function testRegisterRevertsIfGasCommittedExceedsMaxGasCap() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationCore.GasCommittedExceedsMaxGasCap.selector);

        vm.prank(alice);
        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(10_000_001),            // Gas exceeds max gas cap
            uint128(10 gwei),
            uint128(7.01 ether),
            0,
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' registers a UST.
    function testRegister() public {
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

        CommonUtils.TaskDetails memory taskMetadata = registry.getTaskDetails(0);
        assertTrue(registry.ifTaskExists(0));
        assertEq(registry.totalTasks(), 1);
        assertEq(registry.getNextTaskIndex(), 1);
        assertEq(registry.getGasCommittedForNextCycle(), 1_000_000);
        assertEq(automationCore.getTotalDepositedAutomationFees(), 0.5 ether);
        assertEq(erc20Supra.balanceOf(address(automationCore)), 0.502 ether);
        assertEq(erc20Supra.balanceOf(alice), 4.498 ether);

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
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 
        
        vm.startPrank(alice);
        erc20Supra.nativeToErc20Supra{value: 5 ether}();
        erc20Supra.approve(address(automationCore), type(uint256).max);

        CommonUtils.TaskDetails memory taskMetadata = CommonUtils.TaskDetails(
            1_000_000,
            10 gwei,
            0.5 ether,
            0.5 ether,
            keccak256("txHash"),
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 2250),
            0,
            CommonUtils.TaskType.UST,
            CommonUtils.TaskState.PENDING,
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

    /// @dev Test to ensure 'registerSystemTask' reverts if caller is not authorized.
    function testRegisterSystemTaskRevertsIfUnauthorizedCaller() public {
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

    /// @dev Test to ensure 'registerSystemTask' reverts if automation is not enabled.
    function testRegisterSystemTaskRevertsIfAutomationNotEnabled() public {
        testGrantAuthorization();
        
        vm.prank(admin);
        automationCore.disableAutomation();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

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

    /// @dev Test to ensure 'registerSystemTask' reverts if registration is disabled.
    function testRegisterSystemTaskRevertsIfRegistrationDisabled() public {
        testGrantAuthorization();
        
        vm.prank(admin);
        automationCore.disableRegistration();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        vm.expectRevert(IAutomationCore.RegistrationDisabled.selector);

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

    /// @dev Test to ensure 'registerSystemTask' reverts if task type is not GST.
    function testRegisterSystemTaskRevertsIfTaskTypeNotGST() public {
        testGrantAuthorization();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        vm.expectRevert(IAutomationCore.InvalidTaskType.selector);

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
        testGrantAuthorization();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IAutomationCore.InvalidTaskDuration.selector);

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
        testGrantAuthorization();
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        vm.expectRevert(IAutomationCore.GasCommittedExceedsMaxGasCap.selector);

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
        assertEq(taskMetadata.priority, 2);
        assertEq(uint8(taskMetadata.taskType), 1);
        assertEq(uint8(taskMetadata.state), 0);
        assertEq(taskMetadata.owner, bob);
        assertEq(taskMetadata.payloadTx, payload);
        assertEq(taskMetadata.auxData, auxData);
    }

    /// @dev Test to ensure 'registerSystemTask' emits event 'SystemTaskRegistered'.
    function testRegisterSystemTaskEmitsEvent() public {
        testGrantAuthorization();
        
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        CommonUtils.TaskDetails memory taskMetadata = CommonUtils.TaskDetails(
            1_000_000,
            0,
            0,
            0,
            keccak256("txHash"),
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 2250),
            2,
            CommonUtils.TaskType.GST,
            CommonUtils.TaskState.PENDING,
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
        vm.prank(admin);
        automationCore.disableAutomation();
        
        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.cancelTask(0);
    }

    /// @dev Test to ensure 'cancelTask' reverts if task does not exist.
    function testCancelTaskRevertsIfTaskDoesNotExist() public {
        vm.expectRevert(IAutomationRegistry.TaskDoesNotExist.selector);

        vm.prank(alice);
        registry.cancelTask(0);
    }

    /// @dev Test to ensure 'cancelTask' reverts if task type is not UST.
    function testCancelTaskRevertsIfTaskTypeNotUST() public {
        testRegisterSystemTask();
        vm.expectRevert(IAutomationRegistry.UnsupportedTaskOperation.selector);

        vm.prank(bob);
        registry.cancelTask(0);
    }

    /// @dev Test to ensure 'cancelTask' reverts if caller is not the task owner.
    function testCancelTaskRevertsIfUnauthorizedCaller() public {
        testRegister();
        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(bob);
        registry.cancelTask(0);
    }

    /// @dev Test to ensure 'cancelTask' cancels a UST.
    function testCancelTask() public {
        testRegister();

        vm.prank(alice);
        registry.cancelTask(0);

        assertFalse(registry.ifTaskExists(0));
        assertEq(registry.totalTasks(), 0);
        assertEq(registry.getGasCommittedForNextCycle(), 0);
        assertEq(automationCore.getTotalDepositedAutomationFees(), 0);
        assertEq(erc20Supra.balanceOf(address(automationCore)), 0.252 ether);
        assertEq(erc20Supra.balanceOf(alice), 4.748 ether);
    }

    /// @dev Test to ensure 'cancelTask' emits event 'TaskCancelled'.
    function testCancelTaskEmitsEvent() public {
        testRegister();
        
        vm.expectEmit(true, true, true, false);
        emit AutomationRegistry.TaskCancelled(0, alice, keccak256("txHash"));

        vm.prank(alice);
        registry.cancelTask(0);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'cancelSystemTask' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'cancelSystemTask' reverts if automation is not enabled. 
    function testCancelSystemTaskRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        automationCore.disableAutomation();
        
        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.cancelSystemTask(0);
    }

    /// @dev Test to ensure 'cancelSystemTask' reverts if task does not exist. 
    function testCancelSystemTaskRevertsIfTaskDoesNotExist() public {
        vm.expectRevert(IAutomationRegistry.TaskDoesNotExist.selector);

        vm.prank(alice);
        registry.cancelSystemTask(0);
    }

    /// @dev Test to ensure 'cancelSystemTask' reverts if task does not exist in system tasks. 
    function testCancelSystemTaskRevertsIfSystemTaskDoesNotExist() public {
        testRegister();
        vm.expectRevert(IAutomationRegistry.SystemTaskDoesNotExist.selector);

        vm.prank(alice);
        registry.cancelSystemTask(0);
    }

    /// @dev Test to ensure 'cancelSystemTask' reverts if caller is not the task owner. 
    function testCancelSystemTaskRevertsIfUnauthorizedCaller() public {
        testRegisterSystemTask();
        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(alice);
        registry.cancelSystemTask(0);
    }

    /// @dev Test to ensure 'cancelSystemTask' cancels a GST. 
    function testCancelSystemTask() public {
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
        testRegisterSystemTask();

        vm.expectEmit(true, true, true, false);
        emit AutomationRegistry.TaskCancelled(0, bob, keccak256("txHash"));

        vm.prank(bob);
        registry.cancelSystemTask(0);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'stopTasks' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'stopTasks' reverts if automation is not enabled. 
    function testStopTasksRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        automationCore.disableAutomation();
        
        uint64[] memory taskIndexes;
        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.stopTasks(taskIndexes);
    }
    
    /// @dev Test to ensure 'stopTasks' reverts if input array is empty. 
    function testStopTasksRevertsIfInputArrayEmpty() public {
        uint64[] memory taskIndexes;
        vm.expectRevert(IAutomationRegistry.TaskIndexesCannotBeEmpty.selector);

        vm.prank(alice);
        registry.stopTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopTasks' reverts if caller is not the task owner. 
    function testStopTasksRevertsIfUnauthorizedCaller() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(bob);
        registry.stopTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopTasks' reverts if task type is not UST. 
    function testStopTasksRevertsIfTaskTypeNotUST() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IAutomationRegistry.UnsupportedTaskOperation.selector);

        vm.prank(bob);
        registry.stopTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopTasks' does nothing if task does not exist. 
    function testStopTasksDoesNothingIfTaskDoesNotExist() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 5;

        vm.prank(alice);
        registry.stopTasks(taskIndexes);

        assertEq(registry.totalTasks(), 1);
        assertEq(automationCore.getTotalDepositedAutomationFees(), 0.5 ether);
    }

    /// @dev Test to ensure 'stopTasks' stops the input UST tasks. 
    function testStopTasks() public {
        testRegister();
        address controllerAddr = registry.automationController();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.warp(2002);
        vm.startPrank(vmSigner, vmSigner);
        AutomationController(controllerAddr).monitorCycleEnd();        
        AutomationController(controllerAddr).processTasks(2, taskIndexes);
        vm.stopPrank();

        assertEq(erc20Supra.balanceOf(address(automationCore)), 0.702 ether);
        assertEq(erc20Supra.balanceOf(alice), 4.298 ether);

        vm.prank(alice);
        registry.stopTasks(taskIndexes);

        assertFalse(registry.ifTaskExists(0));
        assertEq(registry.totalTasks(), 0);
        assertEq(registry.getGasCommittedForNextCycle(), 0);
        assertEq(automationCore.getTotalDepositedAutomationFees(), 0);
        assertEq(erc20Supra.balanceOf(address(automationCore)), 0.18955 ether);
        assertEq(erc20Supra.balanceOf(alice), 4.81045 ether);
    }

    /// @dev Test to ensure 'stopTasks' emits event 'TasksStopped'.  
    function testStopTasksEmitsEvent() public {
        testRegister();
        address controllerAddr = registry.automationController();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.warp(2002);
        vm.startPrank(vmSigner, vmSigner);
        AutomationController(controllerAddr).monitorCycleEnd();        
        AutomationController(controllerAddr).processTasks(2, taskIndexes);
        vm.stopPrank();

        LibRegistry.TaskStopped[] memory stoppedTasks = new LibRegistry.TaskStopped[](1);
        stoppedTasks[0] = LibRegistry.TaskStopped(0, 0.5 ether, 0.01245 ether, keccak256("txHash"));

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.TasksStopped(stoppedTasks, alice);

        vm.prank(alice);
        registry.stopTasks(taskIndexes);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'stopSystemTasks' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'stopSystemTasks' reverts if automation is not enabled.
    function testStopSystemTasksRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        automationCore.disableAutomation();
        
        uint64[] memory taskIndexes;
        vm.expectRevert(IAutomationRegistry.AutomationNotEnabled.selector);

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' reverts if input array is empty.
    function testStopSystemTasksRevertsIfInputArrayEmpty() public {
        uint64[] memory taskIndexes;
        vm.expectRevert(IAutomationRegistry.TaskIndexesCannotBeEmpty.selector);

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' reverts if caller is not the task owner.
    function testStopSystemTasksRevertsIfUnauthorizedCaller() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IAutomationRegistry.UnauthorizedAccount.selector);

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' reverts if task type is not GST.
    function testStopSystemTasksRevertsIfTaskTypeNotGST() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IAutomationRegistry.UnsupportedTaskOperation.selector);

        vm.prank(alice);
        registry.stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' does nothing if task does not exist.
    function testStopSystemTasksDoesNothingIfTaskDoesNotExist() public {
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
        testRegisterSystemTask();
        address controllerAddr = registry.automationController();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.warp(2002);
        vm.prank(vmSigner, vmSigner);
        AutomationController(controllerAddr).monitorCycleEnd();        
        
        vm.prank(vmSigner);
        AutomationController(controllerAddr).processTasks(2, taskIndexes);

        vm.prank(bob);
        registry.stopSystemTasks(taskIndexes);

        assertFalse(registry.ifTaskExists(0));
        assertFalse(registry.ifSysTaskExists(0));
        assertEq(registry.totalTasks(), 0);
        assertEq(registry.totalSystemTasks(), 0);
        assertEq(registry.getSystemGasCommittedForNextCycle(), 1000000);
    }

    /// @dev Test to ensure 'stopSystemTasks' emits event 'TasksStopped'.
    function testStopSystemTasksEmitsEvent() public {
        testRegisterSystemTask();
        address controllerAddr = registry.automationController();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.warp(2002);
        vm.prank(vmSigner, vmSigner);
        AutomationController(controllerAddr).monitorCycleEnd();        
        
        vm.prank(vmSigner);
        AutomationController(controllerAddr).processTasks(2, taskIndexes);

        LibRegistry.TaskStopped[] memory stoppedTasks = new LibRegistry.TaskStopped[](1);
        stoppedTasks[0] = LibRegistry.TaskStopped(0, 0, 0, keccak256("txHash"));

        vm.expectEmit(true, true, false, false);
        emit AutomationRegistry.TasksStopped(stoppedTasks, bob);

        vm.prank(bob);
        registry.stopSystemTasks(taskIndexes);
    }
    
    /// @dev Test to ensure 'removeTask' reverts if caller is not AutomationController.
    function testRemoveTaskRevertsIfCallerNotAutomationController() public {
        vm.expectRevert(IAutomationRegistry.CallerNotController.selector);

        vm.prank(address(automationCore));
        registry.removeTask(0, false);
    }

    /// @dev Test to ensure 'updateTaskState' reverts if caller is not AutomationController.
    function testUpdateTaskStateRevertsIfCallerNotAutomationController() public {
        vm.expectRevert(IAutomationRegistry.CallerNotController.selector);

        vm.prank(address(automationCore));
        registry.updateTaskState(0, CommonUtils.TaskState.ACTIVE);
    }

    /// @dev Test to ensure 'updateRegistryState' reverts if caller is not AutomationController.
    function testUpdateRegistryStateRevertsIfCallerNotAutomationController() public {
        vm.expectRevert(IAutomationRegistry.CallerNotController.selector);

        vm.prank(address(automationCore));
        registry.updateRegistryState(
            1000000,
            1000000,
            1000000,
            0.1 ether,
            0   
        );
    }

    /// @dev Test to ensure 'refundDepositAndDrop' reverts if caller is not AutomationController.
    function testRefundDepositAndDropRevertsIfCallerNotAutomationController() public {
        vm.expectRevert(IAutomationRegistry.CallerNotController.selector);

        vm.prank(address(automationCore));
        registry.refundDepositAndDrop(
            0,
            alice,
            0.01 ether,
            0.1 ether
        );
    }
}