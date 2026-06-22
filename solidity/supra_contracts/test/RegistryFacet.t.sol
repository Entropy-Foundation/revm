// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {BaseDiamondTest, FailingERC20} from "./BaseDiamondTest.t.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(IRegistryFacet.RegistrationDisabled.selector);

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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        
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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        
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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 

        bytes memory predicate = abi.encode(diamondAddr, bytes(""));

        vm.expectRevert(IRegistryFacet.InvalidPayloadLength.selector);

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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 

        bytes memory invalidPayload = hex"1234";    // 2 bytes

        bytes memory predicate = abi.encode(diamondAddr, invalidPayload);

        vm.expectRevert(IRegistryFacet.InvalidPayloadLength.selector);

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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
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
        
        vm.expectRevert(IRegistryFacet.StaticCallToPredicateFailed.selector);

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

    /// @dev Test to ensure 'register' reverts if task capacity is reached.
    function testRegisterRevertsIfTaskCapacityReached() public {
        address diamond = deployCustomRegistry();

        registerUst(diamond, 2450);
        registerUst(diamond, 2450);
        assertEq(IRegistryFacet(diamond).totalTasks(), 2);
        
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamond);
        
        // Third registration should revert with TaskCapacityReached
        vm.expectRevert(IRegistryFacet.TaskCapacityReached.selector);

        vm.prank(alice);
        IRegistryFacet(diamond).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            2,
            auxData
        );
    }
    
    /// @dev Test to ensure 'register' reverts if predicate returns invalid data length.
    function testRegisterRevertsIfPredicateReturnsInvalidLength() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        
        // Create predicate that does not return 32 bytes
        bytes memory predicate = abi.encode(diamondAddr, abi.encodeCall(ICoreFacet.getCycleInfo, ())); 

        vm.expectRevert(IRegistryFacet.InvalidReturnLengthOfPredicate.selector);

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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        
        // Create predicate that doesn't return boolean
        bytes memory predicate = abi.encode(diamondAddr, abi.encodeCall(ICoreFacet.getCycleDuration, ()));

        vm.expectRevert(IRegistryFacet.InvalidReturnTypeOfPredicate.selector);

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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);
        
        vm.expectRevert(IRegistryFacet.InvalidExpiryTime.selector);

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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(IRegistryFacet.InvalidTaskDuration.selector);

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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(IRegistryFacet.TaskExpiresBeforeNextCycle.selector);

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
        bytes memory payload = createPayload(0, address(0), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
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

        vm.expectRevert(IRegistryFacet.InvalidPayloadLength.selector);

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

        vm.expectRevert(IRegistryFacet.InvalidPayloadLength.selector);

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
        bytes memory payload = createPayload(0, alice, abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(IRegistryFacet.InvalidMaxGasAmount.selector);

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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(IRegistryFacet.InvalidGasPriceCap.selector);

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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryFacet.InsufficientFeeCapForCycle.selector,
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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(IRegistryFacet.GasCommittedExceedsMaxGasCap.selector);

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

    /// @dev Test to ensure 'register' reverts when 'transferFrom' returns false.
    function testRegisterRevertsIfTransferFromFails() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100));
        bytes memory predicate = createPredicate(diamondAddr);

        vm.startPrank(alice);
        erc20SupraHandler.deposit{value: 100 ether}();
        erc20Supra.approve(diamondAddr, type(uint256).max);

        vm.etch(address(erc20Supra), address(new FailingERC20()).code);

        vm.expectRevert(IRegistryFacet.TransferFailed.selector);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            2,
            auxData
        );
        vm.stopPrank();
    }

    /// @dev Test to ensure 'register' reverts if a cycle transition is in progress.
    function testRegisterRevertsIfCycleTransitionInProgress() public {
        registerUst(diamondAddr, 2450);

        ( , uint64 startTime, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startTime + duration);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100));
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(IRegistryFacet.CycleTransitionInProgress.selector);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            2,
            auxData
        );
    }

    /// @dev Test to ensure 'register' registers a UST.
    function testRegister() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);
        
        vm.startPrank(alice);
        erc20SupraHandler.deposit{value: 100 ether}();
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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);
        
        vm.startPrank(alice);
        erc20SupraHandler.deposit{value: 100 ether}();
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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
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

        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);
        registerGst(diamondAddr, 2450);
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if registration is disabled.
    function testRegisterSystemTaskRevertsIfRegistrationDisabled() public {
        vm.prank(admin);
        IConfigFacet(diamondAddr).disableRegistration();
    
        vm.expectRevert(IRegistryFacet.RegistrationDisabled.selector);
        registerGst(diamondAddr, 2450);
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if system task capacity is reached.
    function testRegisterSystemTaskRevertsIfSysTaskCapacityReached() public {
        address diamond = deployCustomRegistry();

        registerGst(diamond, 2450);
        registerGst(diamond, 2450);
        assertEq(IRegistryFacet(diamond).totalTasks(), 2);
        assertEq(IRegistryFacet(diamond).totalSystemTasks(), 2);
        
        // Third registration should revert with TaskCapacityReached
        vm.expectRevert(IRegistryFacet.TaskCapacityReached.selector);
        registerGst(diamond, 2450);
    }

    /// @dev Test to ensure 'registerSystemTask' reverts if task duration is greater than system task duration cap.
    function testRegisterSystemTaskRevertsIfInvalidTaskDuration() public {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(IRegistryFacet.InvalidTaskDuration.selector);

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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);

        vm.expectRevert(IRegistryFacet.GasCommittedExceedsMaxGasCap.selector);

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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
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
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
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
        vm.expectRevert(IRegistryFacet.UnsupportedTaskOperation.selector);

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

        vm.expectRevert(IRegistryFacet.UnsupportedTaskOperation.selector);

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

    /// @dev Test to ensure 'stopTasks' reverts when cycle transition is in progress.
    function testStopTasksRevertsIfCycleTransitionInProgress() public {
        registerUst(diamondAddr, 2450);

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        ( , uint64 startTime, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startTime + duration);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        vm.expectRevert(IRegistryFacet.CycleTransitionInProgress.selector);

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

        vm.expectRevert(IRegistryFacet.UnsupportedTaskOperation.selector);

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
        erc20SupraHandler.deposit{value: 100 ether}();

        processCycleTransition(diamondAddr, taskIndexes);

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
        erc20SupraHandler.deposit{value: 100 ether}();

        processCycleTransition(diamondAddr, taskIndexes);

        LibCommon.TaskStopped[] memory stoppedTasks = new LibCommon.TaskStopped[](1);
        stoppedTasks[0] = LibCommon.TaskStopped(0, 60.1 ether, 0.0625 ether, keccak256("txHash"));

        vm.expectEmit(true, true, false, false);
        emit IRegistryFacet.TasksStopped(stoppedTasks, alice);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopTasks(taskUint64);
    }

    /// @dev Test to ensure stopping a PENDING task refunds half the deposit.
    function testStopPendingTask() public {
        registerUst(diamondAddr, 2450);

        uint64[] memory taskUint64 = new uint64[](1);
        taskUint64[0] = 0;

        uint256 balanceBefore = erc20Supra.balanceOf(alice);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 60.1 ether);

        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopTasks(taskUint64);

        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(erc20Supra.balanceOf(alice), balanceBefore + 30.05 ether);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 0);
    }

    /// @dev Test to ensure stopping an expired task refunds the full deposit but returns 0 cycle fee.
    function testStopExpiredTask() public {
        registerUst(diamondAddr, 2450);

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;
        
        processCycleTransition(diamondAddr, taskIndexes);

        // Warp past expiry (task was registered with expiry time = block.timestamp + 1250)
        vm.warp(block.timestamp + 1251);

        uint256 balanceBefore = erc20Supra.balanceOf(alice);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 60.1 ether);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 3 ether);

        uint64[] memory taskUint64 = new uint64[](1);
        taskUint64[0] = 0;
        
        vm.prank(alice);
        IRegistryFacet(diamondAddr).stopTasks(taskUint64);

        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(erc20Supra.balanceOf(alice), balanceBefore + 60.1 ether);  // Cycle fee refund = 0, deposit refund = 60.1 ether
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 0);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 0 ether);
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

        vm.expectRevert(IRegistryFacet.UnsupportedTaskOperation.selector);

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

        processCycleTransition(diamondAddr, taskIndexes);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).stopSystemTasks(taskUint64);

        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertFalse(IRegistryFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(IRegistryFacet(diamondAddr).getTasksByAddress(bob).length, 0);
        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 0);
        assertEq(IRegistryFacet(diamondAddr).totalSystemTasks(), 0);
        assertEq(IRegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 0);
    }

    /// @dev Test to ensure 'stopSystemTasks' emits event 'TasksStopped'.
    function testStopSystemTasksEmitsEvent() public {
        testRegisterSystemTask();

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;

        uint64[] memory taskUint64 = new uint64[](1);
        taskUint64[0] = 0;

        processCycleTransition(diamondAddr, taskIndexes);

        LibCommon.TaskStopped[] memory stoppedTasks = new LibCommon.TaskStopped[](1);
        stoppedTasks[0] = LibCommon.TaskStopped(0, 0, 0, keccak256("txHash"));

        vm.expectEmit(true, true, false, false);
        emit IRegistryFacet.TasksStopped(stoppedTasks, bob);

        vm.prank(bob);
        IRegistryFacet(diamondAddr).stopSystemTasks(taskUint64);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to view functions ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'getTaskIdList' returns correct task IDs.
    function testGetTaskIdList() public {
        registerUst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);

        uint256[] memory taskIds = IRegistryFacet(diamondAddr).getTaskIdList();
        assertEq(taskIds.length, 2);
        assertEq(taskIds[0], 0);
        assertEq(taskIds[1], 1);
    }

    /// @dev Test to ensure 'getSystemTaskIds' returns correct system task IDs.
    function testGetSystemTaskIds() public {
        registerGst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);

        uint256[] memory sysTaskIds = IRegistryFacet(diamondAddr).getSystemTaskIds();
        assertEq(sysTaskIds.length, 2);
        assertEq(sysTaskIds[0], 0);
        assertEq(sysTaskIds[1], 1);
    }

    /// @dev Test to ensure 'getTaskOwner' returns correct owner for an existing task.
    function testGetTaskOwner() public {
        registerUst(diamondAddr, 2450);

        address owner = IRegistryFacet(diamondAddr).getTaskOwner(0);
        assertEq(owner, alice);
    }

    /// @dev Test to ensure 'getTotalActiveTasks' returns the correct count of active tasks.
    function testGetTotalActiveTasks() public {
        registerUst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);
        
        uint256[] memory taskIndexes = new uint256[](2);
        taskIndexes[0] = 0;
        taskIndexes[1] = 1;

        processCycleTransition(diamondAddr, taskIndexes);

        assertEq(IRegistryFacet(diamondAddr).getTotalActiveTasks(), 2);
    }

    /// @dev Test to ensure 'getTotalActiveTasks' returns zero when no active tasks.
    function testGetTotalActiveTasksZero() public view {
        assertEq(IRegistryFacet(diamondAddr).getTotalActiveTasks(), 0);
    }

    /// @dev Test to ensure 'getActiveTaskIds' returns correct active task IDs.
    function testGetActiveTaskIds() public {
        registerUst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);

        uint256[] memory taskIndexes = new uint256[](2);
        taskIndexes[0] = 0;
        taskIndexes[1] = 1;

        processCycleTransition(diamondAddr, taskIndexes);

        uint256[] memory activeIds = IRegistryFacet(diamondAddr).getActiveTaskIds();
        assertEq(activeIds.length, 2);
        assertEq(activeIds[0], 0);
        assertEq(activeIds[1], 1);
    }

    /// @dev Test to ensure 'getActiveTaskIds' returns empty array when no tasks are active.
    function testGetActiveTaskIdsEmpty() public view {
        assertEq(IRegistryFacet(diamondAddr).getActiveTaskIds().length, 0);
    }

    /// @dev Test to ensure 'getTotalLockedBalance' returns the correct locked balance.
    function testGetTotalLockedBalance() public {
        registerUst(diamondAddr, 2450);

        assertEq(IRegistryFacet(diamondAddr).getTotalLockedBalance(), 60.1 ether);
    }

    /// @dev Test to ensure 'hasActiveUserTask' returns true for an active task.
    function testHasActiveUserTask() public {
        registerUst(diamondAddr, 2450);

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;

        processCycleTransition(diamondAddr, taskIndexes);

        assertTrue(IRegistryFacet(diamondAddr).hasActiveUserTask(alice, 0));
    }

    /// @dev Test to ensure 'hasActiveUserTask' returns false for a pending or non-existent task.
    function testHasActiveUserTaskForPendingOrNonExistent() public {
        registerUst(diamondAddr, 2450);

        assertFalse(IRegistryFacet(diamondAddr).hasActiveUserTask(alice, 0));
        assertFalse(IRegistryFacet(diamondAddr).hasActiveUserTask(alice, 99));
    }

    /// @dev Test to ensure 'hasActiveSystemTask' returns true for an active system task.
    function testHasActiveSystemTask() public {
        registerGst(diamondAddr, 2450);

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;

        processCycleTransition(diamondAddr, taskIndexes);

        assertTrue(IRegistryFacet(diamondAddr).hasActiveSystemTask(bob, 0));
    }

    /// @dev Test to ensure 'hasActiveSystemTask' returns false for a pending or non-existent system task.
    function testHasActiveSystemTaskForPendingOrNonExistent() public {
        registerGst(diamondAddr, 2450);

        assertFalse(IRegistryFacet(diamondAddr).hasActiveSystemTask(bob, 0));
        assertFalse(IRegistryFacet(diamondAddr).hasActiveSystemTask(bob, 99));
    }

    /// @dev Test to ensure 'hasActiveTaskOfType' returns correct values.
    function testHasActiveTaskOfType() public {
        registerUst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);

        uint256[] memory taskIndexes = new uint256[](2);
        taskIndexes[0] = 0;
        taskIndexes[1] = 1;

        processCycleTransition(diamondAddr, taskIndexes);

        assertTrue(IRegistryFacet(diamondAddr).hasActiveTaskOfType(alice, 0, LibCommon.TaskType.UST));
        assertTrue(IRegistryFacet(diamondAddr).hasActiveTaskOfType(bob, 1, LibCommon.TaskType.GST));
    }

    /// @dev Test to ensure 'hasActiveTaskOfType' returns false for pending or non-existent task.
    function testHasActiveTaskOfTypeForPendingOrNonExistent() public {
        registerUst(diamondAddr, 2450);

        assertFalse(IRegistryFacet(diamondAddr).hasActiveTaskOfType(alice, 0, LibCommon.TaskType.UST));
        assertFalse(IRegistryFacet(diamondAddr).hasActiveTaskOfType(alice, 99, LibCommon.TaskType.UST));
    }

    /// @dev Test to ensure 'getTaskDetailsBulk' returns correct details for existing and non-existing tasks.
    function testGetTaskDetailsBulk() public {
        registerUst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);

        uint64[] memory taskIndexes = new uint64[](3);
        taskIndexes[0] = 0;
        taskIndexes[1] = 1;
        taskIndexes[2] = 99;

        TaskMetadata[] memory details = IRegistryFacet(diamondAddr).getTaskDetailsBulk(taskIndexes);
        assertEq(details.length, 2);
        assertEq(details[0].taskIndex, 0);
        assertEq(details[0].owner, alice);
        assertEq(details[1].taskIndex, 1);
        assertEq(details[1].owner, bob);
    }

    /// @dev Test to ensure 'calculateAutomationFeeMultiplierForCurrentCycle' returns the base fee when
    ///      usage is below the 50% threshold, and a higher fee when it exceeds the threshold.
    function testCalculateAutomationFeeMultiplierForCurrentCycle() public {
        // Scenario 1. Register a 100_000-gas task and process first cycle transition
        registerUst(diamondAddr, 1250);
        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;
        processCycleTransition(diamondAddr, taskIndexes);

        // 100_000 gas committed but below 50% threshold (10_000_000) → returns base fee
        assertEq(IRegistryFacet(diamondAddr).calculateAutomationFeeMultiplierForCurrentCycle(), 0.5 ether);


        // Scenario 2. Register a 10_500_000-gas task to push usage above the threshold
        vm.deal(alice, 800 ether);
        vm.startPrank(alice);
        erc20SupraHandler.deposit{value: 800 ether}();
        erc20Supra.approve(diamondAddr, type(uint256).max);
        bytes[] memory auxData;
        IRegistryFacet(diamondAddr).register(
            createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)),
            createPredicate(diamondAddr),
            uint64(block.timestamp) + 1250,
            uint128(10_500_000),
            uint128(4 gwei),
            uint128(400 ether),
            2,
            auxData
        );
        vm.stopPrank();

        // Process cycle transition 
        ( , uint64 startTime, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startTime + duration);

        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();
        
        (uint64 index, , , ) = ICoreFacet(diamondAddr).getCycleInfo();
        uint256[] memory taskIds = new uint256[](2);
        taskIds[0] = 0;
        taskIds[1] = 1;
        ICoreFacet(diamondAddr).processTasks(index + 1, taskIds);
        vm.stopPrank();

        // 10_500_000 gas > 50% threshold (10_000_000) → congestion fee added
        assertEq(IRegistryFacet(diamondAddr).calculateAutomationFeeMultiplierForCurrentCycle(), 0.579846705 ether);
    }

    /// @dev Test to ensure 'estimateAutomationFeeWithCommittedOccupancy' returns zero for zero occupancy,
    ///      scales linearly with task occupancy when total is below the 50% threshold, and increases
    ///      when gas usage pushes total above the threshold.
    function testEstimateAutomationFeeWithCommittedOccupancy() public view {
        // Scenario 1: Zero task occupancy → fee is zero regardless of committed occupancy
        assertEq(IRegistryFacet(diamondAddr).estimateAutomationFeeWithCommittedOccupancy(0, 0), 0);
        assertEq(IRegistryFacet(diamondAddr).estimateAutomationFeeWithCommittedOccupancy(0, 10_000_000), 0);

        // Scenario 2: Total committed gas below 50% threshold → linear scaling with task occupancy
        // (100_000 + 5_000_000 = 5_100_000 < 10_000_000) → 3 ether
        assertEq(IRegistryFacet(diamondAddr).estimateAutomationFeeWithCommittedOccupancy(100_000, 5_000_000), 3 ether);
        // (200_000 + 5_000_000 = 5_200_000 < 10_000_000) → 6 ether (occupancy doubled)
        assertEq(IRegistryFacet(diamondAddr).estimateAutomationFeeWithCommittedOccupancy(200_000, 5_000_000), 6 ether);

        // Scenario 3: Total committed gas above 50% threshold → congestion fee is added
        // (100_000 + 10_000_000 = 10_100_000 > 10_000_000)
        assertEq(IRegistryFacet(diamondAddr).estimateAutomationFeeWithCommittedOccupancy(100_000, 10_000_000), 3.0911325 ether);
        // (100_000 + 15_000_000 = 15_100_000 > 10_000_000, more congestion)
        assertEq(IRegistryFacet(diamondAddr).estimateAutomationFeeWithCommittedOccupancy(100_000, 15_000_000), 11.72151126 ether);
    }
}