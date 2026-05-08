// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {LibCore} from "../src/libraries/LibCore.sol";
import {LibDiamond} from "../src/libraries/LibDiamond.sol";
import {Deployment, InitParams, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";
import {ERC20SupraHandler} from "../src/ERC20SupraHandler.sol";

contract CoreFacetTest is BaseDiamondTest {

    /// @dev Test to ensure 'monitorCycleEnd' reverts if tx.origin is not VM Signer.
    function testMonitorCycleEndRevertsIfTxOriginNotVm() public {
        vm.expectRevert(LibUtils.CallerNotVmSigner.selector);

        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();
    }

    /// @dev Test to ensure 'monitorCycleEnd' does nothing before cycle expiry.
    function testMonitorCycleEndDoesNothingBeforeCycleExpiry() public {
        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();

        assertEq(indexAfter, indexBefore);
        assertEq(startAfter, startBefore);
        assertEq(durationAfter, durationBefore);
        assertEq(uint8(stateAfter), uint8(stateBefore));
    }

    /// @dev Test to ensure 'monitorCycleEnd' does nothing if state is not STARTED.
    function testMonitorCycleEndDoesNothingIfNotStarted() public {
        vm.startPrank(admin);
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600,
            registryMaxGasCap: 10_000_000,
            automationBaseFeeWeiPerSec: 0.001 ether,
            flatRegistrationFeeWei: 0.002 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.002 ether,
            congestionExponent: 2,
            taskCapacity: 500,
            cycleDurationSecs: 2000,
            sysTaskDurationCapSecs: 3600,
            sysRegistryMaxGasCap: 5_000_000,
            sysTaskCapacity: 500,
            registrationEnabled: false,
            automationEnabled: false
        }); 

        Deployment memory deployment = LibDiamondUtils.deploy(admin, address(erc20Supra), initParams);

        address diamondAddr = deployment.diamond;
        vm.stopPrank();

        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.READY));

        vm.warp(startBefore + durationBefore);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();

        assertEq(indexAfter, indexBefore);
        assertEq(startAfter, startBefore);
        assertEq(durationAfter, durationBefore);
        assertEq(uint8(stateAfter), uint8(stateBefore));
    }

    /// @dev Test to ensure 'monitorCycleEnd' moves cycle state to READY if automation is disabled and no tasks exist.
    function testMonitorCycleEndWhenAutomationDisabledNoTasks() public {
        // Disable automation
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        assertFalse(ICoreFacet(diamondAddr).isAutomationEnabled());

        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startBefore + durationBefore);
        
        vm.expectEmit(true, true, false, true);
        emit ICoreFacet.AutomationCycleEvent(
            indexBefore, 
            LibCommon.CycleState.READY,
            startBefore,
            durationBefore,
            stateBefore
        );

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();

        assertEq(indexAfter, indexBefore);
        assertEq(startAfter, startBefore);
        assertEq(durationAfter, durationBefore);
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.READY));
    }

    /// @dev Test to ensure 'monitorCycleEnd' moves cycle state to STARTED if automation is enabled and no tasks exist.
    function testMonitorCycleEndWhenAutomationEnabledNoTasks() public {
        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();

        vm.warp(startBefore + durationBefore);

        vm.expectEmit(true, true, false, true);
        emit ICoreFacet.AutomationCycleEvent(
            indexBefore + 1,
            LibCommon.CycleState.STARTED, 
            uint64(block.timestamp), 
            durationBefore, 
            stateBefore
        );

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();

        assertEq(indexAfter, indexBefore + 1);
        assertEq(startAfter, block.timestamp);
        assertEq(durationAfter, durationBefore);
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.STARTED));
    }

    /// @dev Test to ensure 'monitorCycleEnd' moves cycle state to FINISHED if automation is enabled and tasks exist.
    function testMonitorCycleEndWhenAutomationEnabledAndTasksExist() public {
        registerUst();

        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startBefore + durationBefore);

        vm.expectEmit(true, true, false, true);
        emit ICoreFacet.AutomationCycleEvent(
            indexBefore,
            LibCommon.CycleState.FINISHED,
            startBefore,
            durationBefore,
            stateBefore
        );

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();

        assertEq(indexAfter, indexBefore);
        assertEq(startAfter, startBefore);
        assertEq(durationAfter, durationBefore);
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.FINISHED));

        (uint64 refundDuration, uint128 automationFeePerSec) = ICoreFacet(diamondAddr).getTransitionInfo();
        assertEq(refundDuration, 0);
        assertEq(automationFeePerSec, 0.5 ether);
    }

    /// @dev Test to ensure 'processTasks' reverts if caller is not VM Signer.
    function testProcessTasksRevertsIfNotVm() public {
        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        vm.expectRevert(LibUtils.CallerNotVmSigner.selector);

        vm.prank(admin);
        ICoreFacet(diamondAddr).processTasks(1, tasks);
    }

    /// @dev Test to ensure 'processTasks' reverts if state is not FINISHED or SUSPENDED.
    function testProcessTasksRevertsIfInvalidState() public {
        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        vm.expectRevert(ICoreFacet.InvalidRegistryState.selector);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(1, tasks);
    }

    /// @dev Test to ensure 'processTasks' works correctly when cycle state is FINISHED.
    function testProcessTasksWhenCycleStateFinished() public {
        registerUst();

        ( , uint64 startTime, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startTime + duration);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 index, , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.FINISHED));

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        uint256[] memory activeTasks = new uint256[](1);
        tasks[0] = 0;

        vm.deal(alice, 200 ether);
        vm.prank(alice);
        erc20SupraHandler.deposit{value: 100 ether}();

        vm.expectEmit(true, false, false, false);
        emit ICoreFacet.ActiveTasks(activeTasks);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(index + 1, tasks);

        (uint64 newIndex, uint64 newStart, uint64 newDuration, LibCommon.CycleState newState) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(newIndex, index + 1);
        assertEq(newStart, uint64(block.timestamp));
        assertEq(newDuration, 1200);
        assertEq(uint8(newState), uint8(LibCommon.CycleState.STARTED));

        assertEq(IRegistryFacet(diamondAddr).getActiveTaskIds(), activeTasks);
        assertEq(IRegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 0);
        assertEq(IRegistryFacet(diamondAddr).getSystemGasCommittedForCurrentCycle(), 0);
        assertEq(IRegistryFacet(diamondAddr).getGasCommittedForNextCycle(), 0);
        assertEq(IRegistryFacet(diamondAddr).getGasCommittedForCurrentCycle(), 100000);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 3 ether);
    }

    /// @dev Test to ensure 'processTasks' reverts if invalid cycle index is passed when cycle state is FINISHED.
    function testProcessTasksRevertsIfInvalidCycleIndexWhenCycleStateFinished() public {
        registerUst();

        ( , uint64 startTime, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startTime + duration);
        
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 index, , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.FINISHED));

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        vm.expectRevert(LibCore.InvalidInputCycleIndex.selector);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(index, tasks);
    }

    /// @dev Test to ensure 'processTasks' works correctly when cycle state is SUSPENDED and automation is disabled.
    function testProcessTasksWhenCycleStateSuspendedAutomationDisabled() public {
        registerUst();

        ( , uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);
        
        // Moves state to FINISHED
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        ( , , , LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.FINISHED));

        // Disable automation → moves state to SUSPENDED
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        (uint64 indexAfter, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.SUSPENDED));

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        uint64[] memory tasksUint64 = new uint64[](1);
        tasksUint64[0] = 0;

        vm.expectEmit(true, false, false, false);
        emit ICoreFacet.RemovedTasks(tasksUint64);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(indexAfter, tasks);

        ( , , , LibCommon.CycleState newState) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(newState), uint8(LibCommon.CycleState.READY));
        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(tasksUint64[0]));
    }   

    /// @dev Test to ensure 'processTasks' works correctly when cycle state is SUSPENDED and automation is enabled.
    function testProcessTasksWhenCycleStateSuspendedAutomationEnabled() public {
        registerUst();

        ( , uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);
        
        // Moves state to FINISHED
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        ( , , , LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.FINISHED));

        // Disable automation → moves state to SUSPENDED
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        (uint64 indexAfter, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.SUSPENDED));

        // Enable automation
        vm.prank(admin);
        ICoreFacet(diamondAddr).enableAutomation();

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        uint64[] memory tasksUint64 = new uint64[](1);
        tasks[0] = 0;

        vm.expectEmit(true, false, false, false);
        emit ICoreFacet.RemovedTasks(tasksUint64);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(indexAfter, tasks);

        (uint64 newIndex, uint64 newStart, uint64 newDuration, LibCommon.CycleState newState) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(newIndex, indexAfter + 1);
        assertEq(newStart, uint64(block.timestamp));
        assertEq(newDuration, 1200);
        assertEq(uint8(newState), uint8(LibCommon.CycleState.STARTED));
        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(tasksUint64[0]));
    }

    /// @dev Test to ensure 'processTasks' reverts if invalid cycle index is passed when cycle state is SUSPENDED.
    function testProcessTasksRevertsIfInvalidCycleIndexWhenCycleStateSuspended() public {
        registerUst();

        ( , uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);

        // Moves state to FINISHED
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        ( , , , LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.FINISHED));

        // Disable automation → moves state to SUSPENDED
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        (uint64 indexAfter, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.SUSPENDED));

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        vm.expectRevert(LibCore.InvalidInputCycleIndex.selector);
        
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(indexAfter + 1, tasks);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'disableAutomation' ::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @dev Test to ensure 'disableAutomation' disables the automation.
    function testDisableAutomation() public {
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        assertFalse(ICoreFacet(diamondAddr).isAutomationEnabled());
    }

    /// @dev Test to ensure 'disableAutomation' emits event 'AutomationDisabled'.
    function testDisableAutomationEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit ICoreFacet.AutomationDisabled(false);

        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();
    }

    /// @dev Test to ensure 'disableAutomation' reverts if automation is already disabled.
    function testDisableAutomationRevertsIfAlreadyDisabled() public {
        // Disable automation
        testDisableAutomation();

        // Disable again → revert
        vm.expectRevert(ICoreFacet.AlreadyDisabled.selector);

        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();
    }

    /// @dev Test to ensure 'disableAutomation' reverts if caller is not owner.
    function testDisableAutomationRevertsIfNotOwner() public {
        vm.expectRevert(LibDiamond.MustBeContractOwner.selector);
        
        vm.prank(alice);
        ICoreFacet(diamondAddr).disableAutomation();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'enableAutomation' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'enableAutomation' enables the automation.
    function testEnableAutomation() public {
        // Disable automation
        testDisableAutomation();

        // Enable automation
        vm.prank(admin);
        ICoreFacet(diamondAddr).enableAutomation();

        assertTrue(ICoreFacet(diamondAddr).isAutomationEnabled());
    }

    /// @dev Test to ensure 'enableAutomation' emits event 'AutomationEnabled'.
    function testEnableAutomationEmitsEvent() public {
        // Disable automation
        testDisableAutomation();

        vm.expectEmit(true, false, false, false);
        emit ICoreFacet.AutomationEnabled(true);

        vm.prank(admin);
        ICoreFacet(diamondAddr).enableAutomation();
    }

    /// @dev Test to ensure 'enableAutomation' reverts if automation is already enabled.
    function testEnableAutomationRevertsIfAlreadyEnabled() public {
        vm.expectRevert(ICoreFacet.AlreadyEnabled.selector);

        vm.prank(admin);
        ICoreFacet(diamondAddr).enableAutomation();
    }

    /// @dev Test to ensure 'enableAutomation' reverts if caller is not owner.
    function testEnableAutomationRevertsIfNotOwner() public {
        vm.expectRevert(LibDiamond.MustBeContractOwner.selector);

        vm.prank(alice);
        ICoreFacet(diamondAddr).enableAutomation();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'removeRegisteredTask' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'removeRegisteredTask' removes a UST when predicate validation fails.
    function testRemoveRegisteredTasksForUST() public {
        // Register a UST
        registerUst();
        
        assertTrue(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 1);

        assertEq(IRegistryFacet(diamondAddr).getGasCommittedForNextCycle(), 100_000);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 60.1 ether);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 0 ether);
        assertEq(erc20Supra.balanceOf(diamondAddr), 61.1 ether);
        assertEq(erc20Supra.balanceOf(alice), 38.9 ether);
        
        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;
        uint64[] memory tasksUint64 = new uint64[](1);
        tasksUint64[0] = 0;
        string memory reason = "Predicate failed";


        vm.warp(1201);
        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();        
        ICoreFacet(diamondAddr).processTasks(2, taskIndexes);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 3 ether);

        // Remove task due to predicate failure, cycle index is 2
        ICoreFacet(diamondAddr).removeRegisteredTask(2, tasksUint64[0], reason);
        vm.stopPrank();
        
        // Verify task is removed
        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 0);
        assertEq(IRegistryFacet(diamondAddr).getGasCommittedForNextCycle(), 0);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 0);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 0 ether);
        assertEq(erc20Supra.balanceOf(diamondAddr), 3.9375 ether);
        assertEq(erc20Supra.balanceOf(alice), 96.0625 ether);
    }

    /// @dev Test to ensure 'removeRegisteredTask' removes a GST when predicate validation fails.
    function testRemoveRegisteredTasksForGST() public {
        // Register a GST
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
        
        assertTrue(IRegistryFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(IRegistryFacet(diamondAddr).totalSystemTasks(), 1);
        assertEq(IRegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 100_000);

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;
        uint64[] memory tasksUint64 = new uint64[](1);
        tasksUint64[0] = 0;
        string memory reason = "Predicate failed";

        vm.warp(1201);
        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();        
        ICoreFacet(diamondAddr).processTasks(2, taskIndexes);

        // Remove task due to predicate failure
        ICoreFacet(diamondAddr).removeRegisteredTask(2, tasksUint64[0], reason);
        vm.stopPrank();

        // Verify task is removed
        assertFalse(IRegistryFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(IRegistryFacet(diamondAddr).totalSystemTasks(), 0);
        assertEq(IRegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 100_000);
    }

    /// @dev Test to ensure 'removeRegisteredTask' emits 'TaskRemovedBySystem' event.
    function testRemoveRegisteredTasksEmitsEvent() public {
        registerUst();
        
        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;
        uint64[] memory tasksUint64 = new uint64[](1);
        tasksUint64[0] = 0;
        string memory reason = "Predicate failed";

        vm.warp(1201);
        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();        
        ICoreFacet(diamondAddr).processTasks(2, taskIndexes);

        LibCommon.RemovedTask memory removedTask = LibCommon.RemovedTask(0, LibCommon.TaskType.UST, alice, keccak256("txHash"), "Predicate failed");

        vm.expectEmit(true, false, false, false);
        emit ICoreFacet.TaskRemovedBySystem(removedTask);

        // Remove task due to predicate failure
        ICoreFacet(diamondAddr).removeRegisteredTask(2, tasksUint64[0], reason);
        vm.stopPrank();
    }

    /// @dev Test to ensure 'removeRegisteredTask' reverts if caller is not VM Signer.
    function testRemoveRegisteredTasksRevertsIfNotVmSigner() public {
        registerUst();
        
        vm.expectRevert(LibUtils.CallerNotVmSigner.selector);

        uint64  taskIndex = 0;
        string memory reason = "Predicate failed";

        vm.prank(alice);
        ICoreFacet(diamondAddr).removeRegisteredTask(2, taskIndex, reason);
    }

    /// @dev Test to ensure 'removeRegisteredTask' reverts if cycle index is incorrect.
    function testRemoveRegisteredTasksRevertsIfCycleIndexIncorrect() public {
        registerUst();

        vm.expectRevert(LibCore.InvalidInputCycleIndex.selector);

        uint64  taskIndex = 0;
        string memory reason = "Predicate failed";

        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(2, taskIndex, reason);
    }

    /// @dev Test to ensure 'removeRegisteredTask' reverts if cycle index is incorrect.
    function testRemoveRegisteredTasksRevertsIfCycleIndexIncorrect2() public {
        registerUst();

        vm.expectRevert(LibCore.InvalidInputCycleIndex.selector);

        uint64  taskIndex = 0;
        string memory reason = "Predicate failed";

        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(0, taskIndex, reason);
    }

}
