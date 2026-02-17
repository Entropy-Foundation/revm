// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {ConfigFacet} from "../src/facets/ConfigFacet.sol";
import {RegistryFacet} from "../src/facets/RegistryFacet.sol";
import {CoreFacet} from "../src/facets/CoreFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {LibRegistry} from "../src/libraries/LibRegistry.sol";
import {TaskMetadata} from "../src/libraries/LibAppStorage.sol";

contract RegistryFacetTest is BaseDiamondTest {

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'register' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'register' reverts if automation is not enabled.
    function testRegisterRevertsIfAutomationNotEnabled() public {
        // Disable automation
        vm.prank(admin);
        CoreFacet(diamondAddr).disableAutomation();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).register(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            uint128(1_000_000),                 // maxGasAmount
            uint128(10 gwei),                   // gasPriceCap
            uint128(0.5 ether),                 // automationFeeCapForCycle
            0,                                  // priority
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'register' reverts if registration is disabled.
    function testRegisterRevertsIfRegistrationDisabled() public {
        // Disable registration
        vm.prank(admin);
        ConfigFacet(diamondAddr).disableRegistration();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(LibRegistry.RegistrationDisabled.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).register(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            uint128(1_000_000),                 // maxGasAmount
            uint128(10 gwei),                   // gasPriceCap
            uint128(0.5 ether),                 // automationFeeCapForCycle
            0,                                  // priority
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'register' reverts if expiry time is equal to or less than registration time.
    function testRegisterRevertsIfInvalidExpiryTime() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(LibRegistry.InvalidExpiryTime.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).register(
            payload,
            uint64(block.timestamp),        // Invalid expiryTime
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if task duration is greater than the task duration cap.
    function testRegisterRevertsIfInvalidTaskDuration() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(LibRegistry.InvalidTaskDuration.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).register(
            payload,
            uint64(block.timestamp + 3601),     // Invalid task duration
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if task expires before the next cycle.
    function testRegisterRevertsIfTaskExpiresBeforeNextCycle() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 
        
        vm.expectRevert(LibRegistry.TaskExpiresBeforeNextCycle.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).register(
            payload,
            uint64(block.timestamp + 2000),     // Task expires before next cycle
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if payload target address is zero.
    function testRegisterRevertsIfPayloadTargetZero() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(0));               // Invalid address: address(0)

        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).register(
            payload,
            uint64(block.timestamp + 2250),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if payload target address is EOA.
    function testRegisterRevertsIfPayloadTargetEoa() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, alice);                    // Invalid address: EOA address being passed

        vm.expectRevert(LibUtils.AddressCannotBeEOA.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).register(
            payload,
            uint64(block.timestamp + 2250),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if 0 is passed as max gas amount.
    function testRegisterRevertsIfMaxGasAmountZero() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(LibRegistry.InvalidMaxGasAmount.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).register(
            payload,
            uint64(block.timestamp + 2250),
            uint128(0),                         // maxGasAmount
            uint128(10 gwei),
            uint128(0.5 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if 0 is passed as gas price cap.
    function testRegisterRevertsIfGasPriceCapZero() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(LibRegistry.InvalidGasPriceCap.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).register(
            payload,
            uint64(block.timestamp + 2250),
            uint128(1_000_000),
            uint128(0),                       // gasPriceCap         
            uint128(0.5 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if automation fee cap is less than the estimated automation fee.
    function testRegisterRevertsIfAutomationFeeCapLessThanEstimated() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));  

        vm.expectRevert(LibRegistry.InsufficientFeeCapForCycle.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).register(
            payload,
            uint64(block.timestamp + 2250),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0),                       // automationFeeCapForCycle
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if gas committed exceeds the registry max gas cap.
    function testRegisterRevertsIfGasCommittedExceedsMaxGasCap() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(LibRegistry.GasCommittedExceedsMaxGasCap.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).register(
            payload,
            uint64(block.timestamp + 2250),
            uint128(10_000_001),            // Gas exceeds max gas cap
            uint128(10 gwei),
            uint128(7.01 ether),
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
        erc20Supra.approve(diamondAddr, type(uint256).max);

        RegistryFacet(diamondAddr).register(
            payload,
            uint64(block.timestamp + 2250),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            4,
            auxData
        );
        vm.stopPrank();

        TaskMetadata memory taskMetadata = RegistryFacet(diamondAddr).getTaskDetails(0);
        assertTrue(RegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(RegistryFacet(diamondAddr).totalTasks(), 1);
        assertEq(RegistryFacet(diamondAddr).getNextTaskIndex(), 1);
        assertEq(RegistryFacet(diamondAddr).getGasCommittedForNextCycle(), 1_000_000);
        assertEq(RegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 0.5 ether);
        assertEq(erc20Supra.balanceOf(diamondAddr), 0.502 ether);
        assertEq(erc20Supra.balanceOf(alice), 4.498 ether);

        assertEq(taskMetadata.maxGasAmount, 1_000_000);
        assertEq(taskMetadata.gasPriceCap, 10 gwei);
        assertEq(taskMetadata.automationFeeCapForCycle, 0.5 ether);
        assertEq(taskMetadata.depositFee, 0.5 ether);
        assertEq(taskMetadata.txHash, keccak256("txHash"));
        assertEq(taskMetadata.taskIndex, 0);
        assertEq(taskMetadata.registrationTime, uint64(block.timestamp));
        assertEq(taskMetadata.expiryTime, uint64(block.timestamp + 2250));
        assertEq(taskMetadata.priority, 0);
        assertEq(uint8(taskMetadata.taskType), 0);
        assertEq(uint8(taskMetadata.taskState), 0);
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
        erc20Supra.approve(diamondAddr, type(uint256).max);

        TaskMetadata memory taskMetadata = TaskMetadata({ 
            maxGasAmount: 1_000_000, 
            gasPriceCap: 10 gwei, 
            automationFeeCapForCycle: 0.5 ether, 
            depositFee: 0.5 ether, 
            txHash: keccak256("txHash"), 
            taskIndex: 0, 
            registrationTime: uint64(block.timestamp), 
            expiryTime: uint64(block.timestamp + 2250), 
            priority: 0, 
            owner: alice, 
            taskType: LibUtils.TaskType.UST, 
            taskState: LibUtils.TaskState.PENDING, 
            payloadTx: payload, 
            auxData: auxData
        });

        vm.expectEmit(true, true, false, true);
        emit RegistryFacet.TaskRegistered(0, alice, 0.002 ether, 0.5 ether, taskMetadata);

        RegistryFacet(diamondAddr).register(
            payload,
            uint64(block.timestamp + 2250),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
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

        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            uint128(1_000_000),                 // maxGasAmount
            2,                                  // priority
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if automation is not enabled.
    function testRegisterSystemTaskRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        CoreFacet(diamondAddr).disableAutomation();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);

        vm.prank(bob);
        RegistryFacet(diamondAddr).registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            uint128(1_000_000),                 // maxGasAmount
            2,                                  // priority
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if registration is disabled.
    function testRegisterSystemTaskRevertsIfRegistrationDisabled() public {
        vm.prank(admin);
        ConfigFacet(diamondAddr).disableRegistration();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        vm.expectRevert(LibRegistry.RegistrationDisabled.selector);

        vm.prank(bob);
        RegistryFacet(diamondAddr).registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            uint128(1_000_000),                 // maxGasAmount
            2,                                  // priority
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if task duration is greater than system task duration cap.
    function testRegisterSystemTaskRevertsIfInvalidTaskDuration() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.expectRevert(LibRegistry.InvalidTaskDuration.selector);

        vm.prank(bob);
        RegistryFacet(diamondAddr).registerSystemTask(
            payload,
            uint64(block.timestamp + 3601),     // Invalid task duration
            uint128(1_000_000), 
            2, 
            auxData
        );   
    }
    
    /// @dev Test to ensure 'registerSystemTask' reverts if gas committed exceeds the system registry max gas cap.
    function testRegisterSystemTaskRevertsIfGasCommittedExceedsMaxGasCap() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        vm.expectRevert(LibRegistry.GasCommittedExceedsMaxGasCap.selector);

        vm.prank(bob);
        RegistryFacet(diamondAddr).registerSystemTask(
            payload,
            uint64(block.timestamp + 2250),
            uint128(5_000_001),                 // Gas exceeds max gas cap
            2,
            auxData
        );
    }

    /// @dev Test to ensure 'registerSystemTask' registers a GST.
    function testRegisterSystemTask() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 

        vm.prank(bob);
        RegistryFacet(diamondAddr).registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            uint128(1_000_000),                 // maxGasAmount
            2,                                  // priority
            auxData                             // aux data
        );
        
        TaskMetadata memory taskMetadata = RegistryFacet(diamondAddr).getTaskDetails(0);
        assertTrue(RegistryFacet(diamondAddr).ifTaskExists(0));
        assertTrue(RegistryFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(RegistryFacet(diamondAddr).totalTasks(), 1);
        assertEq(RegistryFacet(diamondAddr).totalSystemTasks(), 1);
        assertEq(RegistryFacet(diamondAddr).getNextTaskIndex(), 1);
        assertEq(RegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 1_000_000);

        assertEq(taskMetadata.maxGasAmount, 1_000_000);
        assertEq(taskMetadata.gasPriceCap, 0);
        assertEq(taskMetadata.automationFeeCapForCycle, 0);
        assertEq(taskMetadata.depositFee, 0);
        assertEq(taskMetadata.txHash, keccak256("txHash"));
        assertEq(taskMetadata.taskIndex, 0);
        assertEq(taskMetadata.registrationTime, uint64(block.timestamp));
        assertEq(taskMetadata.expiryTime, uint64(block.timestamp + 2250));
        assertEq(taskMetadata.priority, 2);
        assertEq(uint8(taskMetadata.taskType), 1);
        assertEq(uint8(taskMetadata.taskState), 0);
        assertEq(taskMetadata.owner, bob);
        assertEq(taskMetadata.payloadTx, payload);
        assertEq(taskMetadata.auxData, auxData);
    }

    /// @dev Test to ensure 'registerSystemTask' emits event 'SystemTaskRegistered'.
    function testRegisterSystemTaskEmitsEvent() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra));

        TaskMetadata memory taskMetadata = TaskMetadata({ 
            maxGasAmount: 1_000_000, 
            gasPriceCap: 0, 
            automationFeeCapForCycle: 0, 
            depositFee: 0, 
            txHash: keccak256("txHash"), 
            taskIndex: 0, 
            registrationTime: uint64(block.timestamp), 
            expiryTime: uint64(block.timestamp + 2250), 
            priority: 2, 
            owner: bob, 
            taskType: LibUtils.TaskType.GST, 
            taskState: LibUtils.TaskState.PENDING, 
            payloadTx: payload, 
            auxData: auxData
        });

        vm.expectEmit(true, true, false, true);
        emit RegistryFacet.SystemTaskRegistered(0, bob, block.timestamp, taskMetadata);

        vm.prank(bob);
        RegistryFacet(diamondAddr).registerSystemTask(
            payload,                            // payload
            uint64(block.timestamp + 2250),     // expiryTime
            uint128(1_000_000),                 // maxGasAmount
            2,                                  // priority
            auxData                             // aux data
        );
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'cancelTask' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'cancelTask' reverts if automation is not enabled.
    function testCancelTaskRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        CoreFacet(diamondAddr).disableAutomation();

        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).cancelTask(0);
    }

    /// @dev Test to ensure 'cancelTask' reverts if task does not exist.
    function testCancelTaskRevertsIfTaskDoesNotExist() public {
        vm.expectRevert(IRegistryFacet.TaskDoesNotExist.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).cancelTask(0);
    }

    /// @dev Test to ensure 'cancelTask' reverts if task type is not UST.
    function testCancelTaskRevertsIfTaskTypeNotUST() public {
        testRegisterSystemTask();
        vm.expectRevert(IRegistryFacet.UnsupportedTaskOperation.selector);

        vm.prank(bob);
        RegistryFacet(diamondAddr).cancelTask(0);
    }

    /// @dev Test to ensure 'cancelTask' reverts if caller is not the task owner.
    function testCancelTaskRevertsIfUnauthorizedCaller() public {
        testRegister();
        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);

        vm.prank(bob);
        RegistryFacet(diamondAddr).cancelTask(0);
    }

    /// @dev Test to ensure 'cancelTask' cancels a UST.
    function testCancelTask() public {
        testRegister();

        vm.prank(alice);
        RegistryFacet(diamondAddr).cancelTask(0);

        assertFalse(RegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(RegistryFacet(diamondAddr).totalTasks(), 0);
        assertEq(RegistryFacet(diamondAddr).getGasCommittedForNextCycle(), 0);
        assertEq(RegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 0);
        assertEq(erc20Supra.balanceOf(diamondAddr), 0.252 ether);
        assertEq(erc20Supra.balanceOf(alice), 4.748 ether);
    }

    /// @dev Test to ensure 'cancelTask' emits event 'TaskCancelled'.
    function testCancelTaskEmitsEvent() public {
        testRegister();
        
        vm.expectEmit(true, true, true, false);
        emit RegistryFacet.TaskCancelled(0, alice, keccak256("txHash"));

        vm.prank(alice);
        RegistryFacet(diamondAddr).cancelTask(0);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'cancelSystemTask' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'cancelSystemTask' reverts if automation is not enabled. 
    function testCancelSystemTaskRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        CoreFacet(diamondAddr).disableAutomation();

        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).cancelSystemTask(0);
    }

    /// @dev Test to ensure 'cancelSystemTask' reverts if task does not exist. 
    function testCancelSystemTaskRevertsIfTaskDoesNotExist() public {
        vm.expectRevert(IRegistryFacet.TaskDoesNotExist.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).cancelSystemTask(0);
    }

    /// @dev Test to ensure 'cancelSystemTask' reverts if task does not exist in system tasks. 
    function testCancelSystemTaskRevertsIfSystemTaskDoesNotExist() public {
        testRegister();
        vm.expectRevert(IRegistryFacet.SystemTaskDoesNotExist.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).cancelSystemTask(0);
    }

    /// @dev Test to ensure 'cancelSystemTask' reverts if caller is not the task owner. 
    function testCancelSystemTaskRevertsIfUnauthorizedCaller() public {
        testRegisterSystemTask();
        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).cancelSystemTask(0);
    }

    /// @dev Test to ensure 'cancelSystemTask' cancels a GST. 
    function testCancelSystemTask() public {
        testRegisterSystemTask();

        vm.prank(bob);
        RegistryFacet(diamondAddr).cancelSystemTask(0);

        assertFalse(RegistryFacet(diamondAddr).ifTaskExists(0));
        assertFalse(RegistryFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(RegistryFacet(diamondAddr).totalTasks(), 0);
        assertEq(RegistryFacet(diamondAddr).totalSystemTasks(), 0);
        assertEq(RegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 0);
    }

    /// @dev Test to ensure 'cancelSystemTask' emits event 'TaskCancelled'. 
    function testCancelSystemTaskEmitsEvent() public {
        testRegisterSystemTask();

        vm.expectEmit(true, true, true, false);
        emit RegistryFacet.TaskCancelled(0, bob, keccak256("txHash"));

        vm.prank(bob);
        RegistryFacet(diamondAddr).cancelSystemTask(0);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'stopTasks' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'stopTasks' reverts if automation is not enabled. 
    function testStopTasksRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        CoreFacet(diamondAddr).disableAutomation();

        uint64[] memory taskIndexes;
        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).stopTasks(taskIndexes);
    }
    
    /// @dev Test to ensure 'stopTasks' reverts if input array is empty. 
    function testStopTasksRevertsIfInputArrayEmpty() public {
        uint64[] memory taskIndexes;
        vm.expectRevert(IRegistryFacet.TaskIndexesCannotBeEmpty.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).stopTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopTasks' reverts if caller is not the task owner. 
    function testStopTasksRevertsIfUnauthorizedCaller() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);

        vm.prank(bob);
        RegistryFacet(diamondAddr).stopTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopTasks' reverts if task type is not UST. 
    function testStopTasksRevertsIfTaskTypeNotUST() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IRegistryFacet.UnsupportedTaskOperation.selector);

        vm.prank(bob);
        RegistryFacet(diamondAddr).stopTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopTasks' does nothing if task does not exist. 
    function testStopTasksDoesNothingIfTaskDoesNotExist() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 5;

        vm.prank(alice);
        RegistryFacet(diamondAddr).stopTasks(taskIndexes);

        assertEq(RegistryFacet(diamondAddr).totalTasks(), 1);
        assertEq(RegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 0.5 ether);
    }

    /// @dev Test to ensure 'stopTasks' stops the input UST tasks. 
    function testStopTasks() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.warp(2002);
        vm.startPrank(vmSigner, vmSigner);
        CoreFacet(diamondAddr).monitorCycleEnd();        
        CoreFacet(diamondAddr).processTasks(2, taskIndexes);
        vm.stopPrank();

        assertEq(erc20Supra.balanceOf(diamondAddr), 0.702 ether);
        assertEq(erc20Supra.balanceOf(alice), 4.298 ether);

        vm.prank(alice);
        RegistryFacet(diamondAddr).stopTasks(taskIndexes);

        assertFalse(RegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(RegistryFacet(diamondAddr).totalTasks(), 0);
        assertEq(RegistryFacet(diamondAddr).getGasCommittedForNextCycle(), 0);
        assertEq(RegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 0);
        assertEq(erc20Supra.balanceOf(diamondAddr), 0.18955 ether);
        assertEq(erc20Supra.balanceOf(alice), 4.81045 ether);
    }

    /// @dev Test to ensure 'stopTasks' emits event 'TasksStopped'.  
    function testStopTasksEmitsEvent() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.warp(2002);
        vm.startPrank(vmSigner, vmSigner);
        CoreFacet(diamondAddr).monitorCycleEnd();        
        CoreFacet(diamondAddr).processTasks(2, taskIndexes);
        vm.stopPrank();

        LibUtils.TaskStopped[] memory stoppedTasks = new LibUtils.TaskStopped[](1);
        stoppedTasks[0] = LibUtils.TaskStopped(0, 0.5 ether, 0.01245 ether, keccak256("txHash"));

        vm.expectEmit(true, true, false, false);
        emit RegistryFacet.TasksStopped(stoppedTasks, alice);

        vm.prank(alice);
        RegistryFacet(diamondAddr).stopTasks(taskIndexes);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'stopSystemTasks' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'stopSystemTasks' reverts if automation is not enabled.
    function testStopSystemTasksRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        CoreFacet(diamondAddr).disableAutomation();

        uint64[] memory taskIndexes;
        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' reverts if input array is empty.
    function testStopSystemTasksRevertsIfInputArrayEmpty() public {
        uint64[] memory taskIndexes;
        vm.expectRevert(IRegistryFacet.TaskIndexesCannotBeEmpty.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' reverts if caller is not the task owner.
    function testStopSystemTasksRevertsIfUnauthorizedCaller() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' reverts if task type is not GST.
    function testStopSystemTasksRevertsIfTaskTypeNotGST() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IRegistryFacet.UnsupportedTaskOperation.selector);

        vm.prank(alice);
        RegistryFacet(diamondAddr).stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' does nothing if task does not exist.
    function testStopSystemTasksDoesNothingIfTaskDoesNotExist() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 5;

        vm.prank(alice);
        RegistryFacet(diamondAddr).stopSystemTasks(taskIndexes);

        assertEq(RegistryFacet(diamondAddr).totalTasks(), 1);
        assertEq(RegistryFacet(diamondAddr).totalSystemTasks(), 1);
    }

    /// @dev Test to ensure 'stopSystemTasks' stops the input GST tasks.
    function testStopSystemTasks() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.warp(2002);
        vm.prank(vmSigner, vmSigner);
        CoreFacet(diamondAddr).monitorCycleEnd();

        vm.prank(vmSigner);
        CoreFacet(diamondAddr).processTasks(2, taskIndexes);

        vm.prank(bob);
        RegistryFacet(diamondAddr).stopSystemTasks(taskIndexes);

        assertFalse(RegistryFacet(diamondAddr).ifTaskExists(0));
        assertFalse(RegistryFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(RegistryFacet(diamondAddr).totalTasks(), 0);
        assertEq(RegistryFacet(diamondAddr).totalSystemTasks(), 0);
        assertEq(RegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 1000000);
    }

    /// @dev Test to ensure 'stopSystemTasks' emits event 'TasksStopped'.
    function testStopSystemTasksEmitsEvent() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.warp(2002);
        vm.prank(vmSigner, vmSigner);
        CoreFacet(diamondAddr).monitorCycleEnd();

        vm.prank(vmSigner);
        CoreFacet(diamondAddr).processTasks(2, taskIndexes);

        LibUtils.TaskStopped[] memory stoppedTasks = new LibUtils.TaskStopped[](1);
        stoppedTasks[0] = LibUtils.TaskStopped(0, 0, 0, keccak256("txHash"));

        vm.expectEmit(true, true, false, false);
        emit RegistryFacet.TasksStopped(stoppedTasks, bob);

        vm.prank(bob);
        RegistryFacet(diamondAddr).stopSystemTasks(taskIndexes);
    }
}