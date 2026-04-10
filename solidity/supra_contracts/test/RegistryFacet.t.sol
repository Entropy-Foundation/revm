// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {LibRegistry} from "../src/libraries/LibRegistry.sol";
import {TaskMetadata} from "../src/libraries/LibAppStorage.sol";
import {ERC20SupraHandler} from "../src/ERC20SupraHandler.sol";

contract RegistryFacetTest is BaseDiamondTest {

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'register' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'register' reverts if automation is not enabled.
    function testRegisterRevertsIfAutomationNotEnabled() public {
        // Disable automation
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,                            // payload
            predicate,                          // predicate
            uint64(block.timestamp + 1250),     // expiryTime
            uint128(100_000),                   // maxGasAmount
            uint128(4 gwei),                    // gasPriceCap
            uint128(60.1 ether),                // automationFeeCapForCycle
            0,                                  // priority
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'register' reverts if registration is disabled.
    function testRegisterRevertsIfRegistrationDisabled() public {
        // Disable registration
        vm.prank(admin);
        IConfigFacet(diamondAddr).disableRegistration();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibRegistry.RegistrationDisabled.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,                            // payload
            predicate,                          // predicate
            uint64(block.timestamp + 1250),     // expiryTime
            uint128(100_000),                   // maxGasAmount
            uint128(4 gwei),                    // gasPriceCap
            uint128(60.1 ether),                // automationFeeCapForCycle
            0,                                  // priority
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'register' reverts if predicate target address is zero.
    function testRegisterRevertsIfPredicateTargetZero() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        
        // Create predicate with address(0) as target 
        bytes memory predicate = createPredicate(address(0));
        
        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if predicate target address is EOA.
    function testRegisterRevertsIfPredicateTargetEoa() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        
        // Create predicate with EOA as target address
        bytes memory predicate = createPredicate(alice);
        
        vm.expectRevert(LibUtils.AddressCannotBeEOA.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if predicate payload is empty.
    function testRegisterRevertsIfPredicatePayloadEmpty() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 

        bytes memory predicate = abi.encode(diamondAddr, bytes(""));

        vm.expectRevert(LibRegistry.InvalidPayloadLength.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    } 
    
    /// @dev Test to ensure 'register' reverts if predicate payload is too short.
    function testRegisterRevertsIfPredicatePayloadTooShort() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 

        bytes memory invalidPayload = hex"1234";    // 2 bytes

        bytes memory predicate = abi.encode(diamondAddr, invalidPayload);

        vm.expectRevert(LibRegistry.InvalidPayloadLength.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if predicate updates state.
    function testRegisterRevertsIfPredicateUpdatesState() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);
    
        // Create predicate that updates state
        bytes memory invalidPredicate = abi.encode(
            diamondAddr, abi.encodeCall(IRegistryFacet.register, (
                payload,
                predicate,
                uint64(block.timestamp + 1250),
                uint128(100_000),
                uint128(4 gwei),
                uint128(60.1 ether),
                0,
                auxData
            ))
        );
        
        vm.expectRevert(LibRegistry.StaticCallToPredicateFailed.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            invalidPredicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if predicate returns invalid data length.
    function testRegisterRevertsIfPredicateReturnsInvalidLength() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        
        // Create predicate that does not return 32 bytes
        bytes memory predicate = abi.encode(diamondAddr, abi.encodeCall(ICoreFacet.getCycleInfo, ())); 

        vm.expectRevert(LibRegistry.InvalidReturnLengthOfPredicate.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if predicate returns invalid return type.
    function testRegisterRevertsIfPredicateReturnsInvalidType() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        
        // Create predicate that doesn't return boolean
        bytes memory predicate = abi.encode(diamondAddr, abi.encodeCall(ICoreFacet.getCycleDuration, ()));

        vm.expectRevert(LibRegistry.InvalidReturnTypeOfPredicate.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if expiry time is equal to or less than registration time.
    function testRegisterRevertsIfInvalidExpiryTime() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);
        
        vm.expectRevert(LibRegistry.InvalidExpiryTime.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp),        // Invalid expiryTime
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if task duration is greater than the task duration cap.
    function testRegisterRevertsIfInvalidTaskDuration() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibRegistry.InvalidTaskDuration.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + (3600 * 24 * 7) + 1),     // Invalid task duration
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if task expires before the next cycle.
    function testRegisterRevertsIfTaskExpiresBeforeNextCycle() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibRegistry.TaskExpiresBeforeNextCycle.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1200),     // Task expires before next cycle
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if payload target address is zero.
    function testRegisterRevertsIfPayloadTargetZero() public {
        bytes[] memory auxData;
        // Invalid address: address(0)
        bytes memory payload = createPayload(0, address(0), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if payload calldata is empty.
    function testRegisterRevertsIfPayloadCalldataEmpty() public {
        bytes[] memory auxData;

        // Create payload with empty calldata
        bytes memory payload = createPayload(0, address(erc20SupraHandler), bytes("")); 

        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibRegistry.InvalidPayloadLength.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if calldata length is less than 4 bytes.
    function testRegisterRevertsIfPayloadCalldataTooShort() public {
        bytes[] memory auxData;

        // Create payload with invalid calldata
        bytes memory payload = createPayload(0, address(erc20SupraHandler), hex"1234"); 

        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibRegistry.InvalidPayloadLength.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if payload target address is EOA.
    function testRegisterRevertsIfPayloadTargetEoa() public {
        bytes[] memory auxData;
        // Invalid address: EOA address being passed
        bytes memory payload = createPayload(0, alice, abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibUtils.AddressCannotBeEOA.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if 0 is passed as max gas amount.
    function testRegisterRevertsIfMaxGasAmountZero() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibRegistry.InvalidMaxGasAmount.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(0),                         // maxGasAmount
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if 0 is passed as gas price cap.
    function testRegisterRevertsIfGasPriceCapZero() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibRegistry.InvalidGasPriceCap.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(0),                       // gasPriceCap         
            uint128(60.1 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if automation fee cap is less than the estimated automation fee.
    function testRegisterRevertsIfAutomationFeeCapLessThanEstimated() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibRegistry.InsufficientFeeCapForCycle.selector,
                3 ether
            )
        );

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(0),                       // automationFeeCapForCycle
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' reverts if gas committed exceeds the registry max gas cap.
    function testRegisterRevertsIfGasCommittedExceedsMaxGasCap() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibRegistry.GasCommittedExceedsMaxGasCap.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(20_000_001),            // Gas exceeds max gas cap
            uint128(4 gwei),
            uint128(6835 ether),
            0,
            auxData
        );
    }

    /// @dev Test to ensure 'register' registers a UST.
    function testRegister() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);
        
        vm.startPrank(alice);
        erc20SupraHandler.nativeToErc20Supra{value: 100 ether}();
        erc20Supra.approve(diamondAddr, type(uint256).max);

        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            4,
            auxData
        );
        vm.stopPrank();

        TaskMetadata memory taskMetadata = IRegistryFacet(diamondAddr).getTaskDetails(0);
        assertTrue(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 1);

        uint256[] memory userTasks = IRegistryFacet(diamondAddr).getTasksByAddress(alice);
        assertEq(userTasks.length, 1);
        assertEq(userTasks[0], 0);

        assertEq(IRegistryFacet(diamondAddr).getNextTaskIndex(), 1);
        assertEq(IRegistryFacet(diamondAddr).getGasCommittedForNextCycle(), 100_000);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 60.1 ether);
        assertEq(erc20Supra.balanceOf(diamondAddr), 61.1 ether);
        assertEq(erc20Supra.balanceOf(alice), 38.9 ether);

        assertEq(taskMetadata.maxGasAmount, 100_000);
        assertEq(taskMetadata.gasPriceCap, 4 gwei);
        assertEq(taskMetadata.automationFeeCapForCycle, 60.1 ether);
        assertEq(taskMetadata.depositFee, 60.1 ether);
        assertEq(taskMetadata.txHash, keccak256("txHash"));
        assertEq(taskMetadata.taskIndex, 0);
        assertEq(taskMetadata.registrationTime, uint64(block.timestamp));
        assertEq(taskMetadata.expiryTime, uint64(block.timestamp + 1250));
        assertEq(taskMetadata.priority, 0);
        assertEq(uint8(taskMetadata.taskType), 0);
        assertEq(uint8(taskMetadata.taskState), 0);
        assertEq(taskMetadata.owner, alice);
        assertEq(taskMetadata.payloadTx, payload);
        assertEq(taskMetadata.predicate, predicate);
        assertEq(taskMetadata.auxData, auxData);
    }

    /// @dev Test to ensure 'register' emits event 'TaskRegistered'.
    function testRegisterEmitsEvent() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);
        
        vm.startPrank(alice);
        erc20SupraHandler.nativeToErc20Supra{value: 100 ether}();
        erc20Supra.approve(diamondAddr, type(uint256).max);

        TaskMetadata memory taskMetadata = TaskMetadata({ 
            maxGasAmount: 100_000, 
            gasPriceCap: 4 gwei, 
            automationFeeCapForCycle: 60.1 ether, 
            depositFee: 60.1 ether, 
            txHash: keccak256("txHash"), 
            taskIndex: 0, 
            registrationTime: uint64(block.timestamp), 
            expiryTime: uint64(block.timestamp + 1250), 
            priority: 0, 
            owner: alice, 
            taskType: LibCommon.TaskType.UST, 
            taskState: LibCommon.TaskState.PENDING, 
            payloadTx: payload,
            predicate: predicate, 
            auxData: auxData
        });

        vm.expectEmit(true, true, false, true);
        emit IRegistryFacet.TaskRegistered(0, alice, 1 ether, 60.1 ether, taskMetadata);

        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            0,
            auxData
        );
        vm.stopPrank();
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'registerSystemTask' :::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'registerSystemTask' reverts if caller is not authorized.
    function testRegisterSystemTaskRevertsIfUnauthorizedCaller() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).registerSystemTask(
            payload,                            // payload
            predicate,                          // predicate
            uint64(block.timestamp + 1250),     // expiryTime
            uint128(100_000),                   // maxGasAmount
            2,                                  // priority
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if automation is not enabled.
    function testRegisterSystemTaskRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).registerSystemTask(
            payload,                            // payload
            predicate,                          // predicate
            uint64(block.timestamp + 1250),     // expiryTime
            uint128(100_000),                   // maxGasAmount
            2,                                  // priority
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if registration is disabled.
    function testRegisterSystemTaskRevertsIfRegistrationDisabled() public {
        vm.prank(admin);
        IConfigFacet(diamondAddr).disableRegistration();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibRegistry.RegistrationDisabled.selector);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).registerSystemTask(
            payload,                            // payload
            predicate,                          // predicate
            uint64(block.timestamp + 1250),     // expiryTime
            uint128(100_000),                   // maxGasAmount
            2,                                  // priority
            auxData                             // aux data
        );
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if task duration is greater than system task duration cap.
    function testRegisterSystemTaskRevertsIfInvalidTaskDuration() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibRegistry.InvalidTaskDuration.selector);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).registerSystemTask(
            payload,
            predicate,
            uint64(block.timestamp + (3600 * 24 * 180) + 1),     // Invalid task duration
            uint128(100_000), 
            2, 
            auxData
        );   
    }
    
    /// @dev Test to ensure 'registerSystemTask' reverts if gas committed exceeds the system registry max gas cap.
    function testRegisterSystemTaskRevertsIfGasCommittedExceedsMaxGasCap() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(LibRegistry.GasCommittedExceedsMaxGasCap.selector);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).registerSystemTask(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(20_000_001),                 // Gas exceeds max gas cap
            2,
            auxData
        );
    }

    /// @dev Test to ensure 'registerSystemTask' registers a GST.
    function testRegisterSystemTask() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).registerSystemTask(
            payload,                            // payload
            predicate,                          // predicate
            uint64(block.timestamp + 1250),     // expiryTime
            uint128(100_000),                   // maxGasAmount
            2,                                  // priority
            auxData                             // aux data
        );
        
        TaskMetadata memory taskMetadata = IRegistryFacet(diamondAddr).getTaskDetails(0);
        assertTrue(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertTrue(IRegistryFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 1);
        assertEq(IRegistryFacet(diamondAddr).totalSystemTasks(), 1);

        uint256[] memory userTasks = IRegistryFacet(diamondAddr).getTasksByAddress(bob);
        assertEq(userTasks.length, 1);
        assertEq(userTasks[0], 0);

        assertEq(IRegistryFacet(diamondAddr).getNextTaskIndex(), 1);
        assertEq(IRegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 100_000);

        assertEq(taskMetadata.maxGasAmount, 100_000);
        assertEq(taskMetadata.gasPriceCap, 0);
        assertEq(taskMetadata.automationFeeCapForCycle, 0);
        assertEq(taskMetadata.depositFee, 0);
        assertEq(taskMetadata.txHash, keccak256("txHash"));
        assertEq(taskMetadata.taskIndex, 0);
        assertEq(taskMetadata.registrationTime, uint64(block.timestamp));
        assertEq(taskMetadata.expiryTime, uint64(block.timestamp + 1250));
        assertEq(taskMetadata.priority, 2);
        assertEq(uint8(taskMetadata.taskType), 1);
        assertEq(uint8(taskMetadata.taskState), 0);
        assertEq(taskMetadata.owner, bob);
        assertEq(taskMetadata.payloadTx, payload);
        assertEq(taskMetadata.predicate, predicate);
        assertEq(taskMetadata.auxData, auxData);
    }

    /// @dev Test to ensure 'registerSystemTask' emits event 'SystemTaskRegistered'.
    function testRegisterSystemTaskEmitsEvent() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.erc20SupraToNative, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        TaskMetadata memory taskMetadata = TaskMetadata({ 
            maxGasAmount: 100_000, 
            gasPriceCap: 0, 
            automationFeeCapForCycle: 0, 
            depositFee: 0, 
            txHash: keccak256("txHash"), 
            taskIndex: 0, 
            registrationTime: uint64(block.timestamp), 
            expiryTime: uint64(block.timestamp + 1250), 
            priority: 2, 
            owner: bob, 
            taskType: LibCommon.TaskType.GST, 
            taskState: LibCommon.TaskState.PENDING, 
            payloadTx: payload,
            predicate: predicate, 
            auxData: auxData
        });

        vm.expectEmit(true, true, false, true);
        emit IRegistryFacet.SystemTaskRegistered(0, bob, block.timestamp, taskMetadata);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).registerSystemTask(
            payload,                            // payload
            predicate,                          // predicate
            uint64(block.timestamp + 1250),     // expiryTime
            uint128(100_000),                   // maxGasAmount
            2,                                  // priority
            auxData                             // aux data
        );
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'cancelTasks' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'cancelTasks' reverts if automation is not enabled.
    function testCancelTasksRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelTasks(taskIndexes);
    }

    /// @dev Test to ensure 'cancelTasks' reverts if input array is empty. 
    function testCancelTasksRevertsIfInputArrayEmpty() public {
        uint64[] memory taskIndexes;
        vm.expectRevert(IRegistryFacet.TaskIndexesCannotBeEmpty.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelTasks(taskIndexes);
    }

    /// @dev Test to ensure 'cancelTasks' does nothing if task does not exist.
    function testCancelTasksDoesNothingIfTaskDoesNotExist() public {
        testRegister();
        
        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 5;

        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelTasks(taskIndexes);

        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 1);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 60.1 ether);
    }

    /// @dev Test to ensure 'cancelTasks' reverts if task type is not UST.
    function testCancelTasksRevertsIfTaskTypeNotUST() public {
        testRegisterSystemTask();
        vm.expectRevert(LibRegistry.UnsupportedTaskOperation.selector);

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.prank(bob);
        IRegistryFacet(diamondAddr).cancelTasks(taskIndexes);
    }

    /// @dev Test to ensure 'cancelTasks' reverts if caller is not the task owner.
    function testCancelTasksRevertsIfUnauthorizedCaller() public {
        testRegister();
        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.prank(bob);
        IRegistryFacet(diamondAddr).cancelTasks(taskIndexes);
    }

    /// @dev Test to ensure 'cancelTasks' cancels a UST.
    function testCancelTasks() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelTasks(taskIndexes);

        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 0);
        assertEq(IRegistryFacet(diamondAddr).getTasksByAddress(alice).length, 0);
        assertEq(IRegistryFacet(diamondAddr).getGasCommittedForNextCycle(), 0);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 0);
        assertEq(erc20Supra.balanceOf(diamondAddr), 31.05 ether);
        assertEq(erc20Supra.balanceOf(alice), 68.95 ether);
    }

    /// @dev Test to ensure 'cancelTasks' emits event 'TasksCancelled'.
    function testCancelTasksEmitsEvent() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        LibCommon.TaskCancelled[] memory cancelledTasks = new LibCommon.TaskCancelled[](1);
        cancelledTasks[0] = LibCommon.TaskCancelled(0, LibCommon.TaskType.UST, keccak256("txHash"));
        
        vm.expectEmit(true, true, false, false);
        emit IRegistryFacet.TasksCancelled(cancelledTasks, alice);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelTasks(taskIndexes);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'cancelSystemTasks' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'cancelSystemTasks' reverts if automation is not enabled. 
    function testCancelSystemTasksRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'cancelSystemTasks' reverts if input array is empty. 
    function testCancelSystemTasksRevertsIfInputArrayEmpty() public {
        uint64[] memory taskIndexes;
        vm.expectRevert(IRegistryFacet.TaskIndexesCannotBeEmpty.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'cancelSystemTasks' does nothing if task does not exist. 
    function testCancelSystemTasksDoesNothingIfTaskDoesNotExist() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 5;

        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelSystemTasks(taskIndexes);

        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 1);
        assertEq(IRegistryFacet(diamondAddr).totalSystemTasks(), 1);
    }

    /// @dev Test to ensure 'cancelSystemTasks' reverts if task type is not GST. 
    function testCancelSystemTasksRevertsIfTaskTypeNotGST() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(LibRegistry.UnsupportedTaskOperation.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'cancelSystemTasks' reverts if caller is not the task owner. 
    function testCancelSystemTasksRevertsIfUnauthorizedCaller() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'cancelSystemTasks' cancels a GST. 
    function testCancelSystemTasks() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.prank(bob);
        IRegistryFacet(diamondAddr).cancelSystemTasks(taskIndexes);

        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertFalse(IRegistryFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(IRegistryFacet(diamondAddr).getTasksByAddress(bob).length, 0);
        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 0);
        assertEq(IRegistryFacet(diamondAddr).totalSystemTasks(), 0);
        assertEq(IRegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 0);
    }

    /// @dev Test to ensure 'cancelSystemTasks' emits event 'TasksCancelled'. 
    function testCancelSystemTasksEmitsEvent() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        LibCommon.TaskCancelled[] memory cancelledTasks = new LibCommon.TaskCancelled[](1);
        cancelledTasks[0] = LibCommon.TaskCancelled(0, LibCommon.TaskType.GST, keccak256("txHash"));

        vm.expectEmit(true, true, false, false);
        emit IRegistryFacet.TasksCancelled(cancelledTasks, bob);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).cancelSystemTasks(taskIndexes);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'stopTasks' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'stopTasks' reverts if automation is not enabled. 
    function testStopTasksRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        uint64[] memory taskIndexes;
        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopTasks(taskIndexes);
    }
    
    /// @dev Test to ensure 'stopTasks' reverts if input array is empty. 
    function testStopTasksRevertsIfInputArrayEmpty() public {
        uint64[] memory taskIndexes;
        vm.expectRevert(IRegistryFacet.TaskIndexesCannotBeEmpty.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopTasks' reverts if caller is not the task owner. 
    function testStopTasksRevertsIfUnauthorizedCaller() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).stopTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopTasks' reverts if task type is not UST. 
    function testStopTasksRevertsIfTaskTypeNotUST() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(LibRegistry.UnsupportedTaskOperation.selector);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).stopTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopTasks' does nothing if task does not exist. 
    function testStopTasksDoesNothingIfTaskDoesNotExist() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 5;

        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopTasks(taskIndexes);

        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 1);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 60.1 ether);
    }

    /// @dev Test to ensure 'stopTasks' stops the input UST tasks. 
    function testStopTasks() public {
        testRegister();

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;

        uint64[] memory taskUint64 = new uint64[](1);
        taskUint64[0] = 0;

        vm.deal(alice, 200 ether);
        vm.prank(alice);
        erc20SupraHandler.nativeToErc20Supra{value: 100 ether}();

        vm.warp(1201);
        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();        
        ICoreFacet(diamondAddr).processTasks(2, taskIndexes);
        vm.stopPrank();

        assertEq(erc20Supra.balanceOf(diamondAddr), 64.1 ether);
        assertEq(erc20Supra.balanceOf(alice), 135.9 ether);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopTasks(taskUint64);

        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 0);
        assertEq(IRegistryFacet(diamondAddr).getTasksByAddress(alice).length, 0);
        assertEq(IRegistryFacet(diamondAddr).getGasCommittedForNextCycle(), 0);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 0);
        assertEq(erc20Supra.balanceOf(diamondAddr), 3.9375 ether);
        assertEq(erc20Supra.balanceOf(alice), 196.0625 ether);
    }

    /// @dev Test to ensure 'stopTasks' emits event 'TasksStopped'.  
    function testStopTasksEmitsEvent() public {
        testRegister();

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;

        uint64[] memory taskUint64 = new uint64[](1);
        taskUint64[0] = 0;

        vm.deal(alice, 200 ether);
        vm.prank(alice);
        erc20SupraHandler.nativeToErc20Supra{value: 100 ether}();

        vm.warp(1201);
        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();        
        ICoreFacet(diamondAddr).processTasks(2, taskIndexes);
        vm.stopPrank();

        LibCommon.TaskStopped[] memory stoppedTasks = new LibCommon.TaskStopped[](1);
        stoppedTasks[0] = LibCommon.TaskStopped(0, 60.1 ether, 0.0625 ether, keccak256("txHash"));

        vm.expectEmit(true, true, false, false);
        emit IRegistryFacet.TasksStopped(stoppedTasks, alice);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopTasks(taskUint64);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'stopSystemTasks' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'stopSystemTasks' reverts if automation is not enabled.
    function testStopSystemTasksRevertsIfAutomationNotEnabled() public {
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        uint64[] memory taskIndexes;
        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' reverts if input array is empty.
    function testStopSystemTasksRevertsIfInputArrayEmpty() public {
        uint64[] memory taskIndexes;
        vm.expectRevert(IRegistryFacet.TaskIndexesCannotBeEmpty.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' reverts if caller is not the task owner.
    function testStopSystemTasksRevertsIfUnauthorizedCaller() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' reverts if task type is not GST.
    function testStopSystemTasksRevertsIfTaskTypeNotGST() public {
        testRegister();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        vm.expectRevert(LibRegistry.UnsupportedTaskOperation.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopSystemTasks(taskIndexes);
    }

    /// @dev Test to ensure 'stopSystemTasks' does nothing if task does not exist.
    function testStopSystemTasksDoesNothingIfTaskDoesNotExist() public {
        testRegisterSystemTask();

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 5;

        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopSystemTasks(taskIndexes);

        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 1);
        assertEq(IRegistryFacet(diamondAddr).totalSystemTasks(), 1);
    }

    /// @dev Test to ensure 'stopSystemTasks' stops the input GST tasks.
    function testStopSystemTasks() public {
        testRegisterSystemTask();

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;

        uint64[] memory taskUint64 = new uint64[](1);
        taskUint64[0] = 0;

        vm.warp(1201);
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(2, taskIndexes);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).stopSystemTasks(taskUint64);

        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertFalse(IRegistryFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(IRegistryFacet(diamondAddr).getTasksByAddress(bob).length, 0);
        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 0);
        assertEq(IRegistryFacet(diamondAddr).totalSystemTasks(), 0);
        assertEq(IRegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 100000);
    }

    /// @dev Test to ensure 'stopSystemTasks' emits event 'TasksStopped'.
    function testStopSystemTasksEmitsEvent() public {
        testRegisterSystemTask();

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;

        uint64[] memory taskUint64 = new uint64[](1);
        taskUint64[0] = 0;

        vm.warp(1201);
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(2, taskIndexes);

        LibCommon.TaskStopped[] memory stoppedTasks = new LibCommon.TaskStopped[](1);
        stoppedTasks[0] = LibCommon.TaskStopped(0, 0, 0, keccak256("txHash"));

        vm.expectEmit(true, true, false, false);
        emit IRegistryFacet.TasksStopped(stoppedTasks, bob);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).stopSystemTasks(taskUint64);
    }
}