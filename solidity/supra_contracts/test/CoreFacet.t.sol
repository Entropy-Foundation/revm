// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
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

    /// @dev Test to ensure 'monitorCycleEnd' moves cycle state to STARTED if automation is enabled and no tasks exist.
    function testMonitorCycleEndWhenAutomationEnabledNoTasks() public {
        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();

        vm.warp(startBefore + durationBefore);

        vm.expectEmit(true, true, true, true);
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
        registerUst(diamondAddr, 2450);

        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startBefore + durationBefore);

        vm.expectEmit(true, true, true, true);
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
        registerUst(diamondAddr, 2450);

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        processCycleTransition(diamondAddr, tasks);

        (uint64 newIndex, uint64 newStart, uint64 newDuration, LibCommon.CycleState newState) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(newIndex, 2);
        assertEq(newStart, uint64(block.timestamp));
        assertEq(newDuration, 1200);
        assertEq(uint8(newState), uint8(LibCommon.CycleState.STARTED));

        assertEq(IRegistryFacet(diamondAddr).getActiveTaskIds(), tasks);
        assertEq(IRegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 0);
        assertEq(IRegistryFacet(diamondAddr).getSystemGasCommittedForCurrentCycle(), 0);
        assertEq(IRegistryFacet(diamondAddr).getGasCommittedForNextCycle(), 100000);
        assertEq(IRegistryFacet(diamondAddr).getGasCommittedForCurrentCycle(), 100000);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 3 ether);
    }

    /// @dev Test to ensure 'processTasks' reverts if invalid cycle index is passed when cycle state is FINISHED.
    function testProcessTasksRevertsIfInvalidCycleIndexWhenCycleStateFinished() public {
        registerUst(diamondAddr, 2450);

        ( , uint64 startTime, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startTime + duration);
        
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 index, , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.FINISHED));

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        vm.expectRevert(ICoreFacet.InvalidInputCycleIndex.selector);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(index, tasks);
    }

    /// @notice Test to ensure 'processTasks' reverts if tasks are processed out of order.
    function testProcessTasksRevertsIfTasksOutOfOrder() public {
        registerUst(diamondAddr, 2450);
        registerUst(diamondAddr, 2450);

        ( , uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 index, , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.FINISHED));

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 1;

        vm.expectRevert(ICoreFacet.OutOfOrderTaskProcessingRequest.selector);

        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(index + 1, tasks);
    }

    /// @dev Test to ensure 'processTasks' works correctly when cycle state is SUSPENDED and automation is disabled.
    function testProcessTasksWhenCycleStateSuspendedAutomationDisabled() public {
        registerUst(diamondAddr, 2450);

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
        registerUst(diamondAddr, 2450);

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
        registerUst(diamondAddr, 2450);

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

        vm.expectRevert(ICoreFacet.InvalidInputCycleIndex.selector);
        
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

    /// @dev Test to ensure 'disableAutomation' moves cycle state from STARTED to READY if automation is disabled and no tasks exist.
    function testDisableAutomationStartedToReadyWhenNoTasksExist() public {
        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.STARTED));

        vm.expectEmit(true, true, true, true);
        emit ICoreFacet.AutomationCycleEvent(
            indexBefore, 
            LibCommon.CycleState.READY,
            startBefore,
            durationBefore,
            stateBefore
        );

        // Disable automation
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        assertFalse(ICoreFacet(diamondAddr).isAutomationEnabled());
        
        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(indexBefore, indexAfter);
        assertEq(startBefore, startAfter);
        assertEq(durationBefore, durationAfter);
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.READY));
    }

    /// @dev Test to ensure 'disableAutomation' moves cycle state from STARTED to SUSPENDED if automation is disabled and tasks exist.
    function testDisableAutomationStartedToSuspendedWhenTasksExist() public {
        registerUst(diamondAddr, 2450);
        
        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.STARTED));

        vm.expectEmit(true, true, true, true);
        emit ICoreFacet.AutomationCycleEvent(
            indexBefore, 
            LibCommon.CycleState.SUSPENDED,
            startBefore,
            durationBefore,
            stateBefore
        );

        // Disable automation
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        assertFalse(ICoreFacet(diamondAddr).isAutomationEnabled());
        
        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(indexBefore, indexAfter);
        assertEq(startBefore, startAfter);
        assertEq(durationBefore, durationAfter);
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.SUSPENDED));
    }

    /// @dev Test to ensure 'disableAutomation' moves cycle state from FINISHED to SUSPENDED if automation is disabled and transition is not started.
    function testDisableAutomationFinishedToSuspendedWhenTransitionNotStarted() public {
        registerUst(diamondAddr, 2450);

        ( , uint64 startTime, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startTime + duration);
        
        // Moves state to FINISHED
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.FINISHED));

        vm.expectEmit(true, true, true, true);
        emit ICoreFacet.AutomationCycleEvent(
            indexBefore, 
            LibCommon.CycleState.SUSPENDED,
            startBefore,
            durationBefore,
            stateBefore
        );

        // Disable automation
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        assertFalse(ICoreFacet(diamondAddr).isAutomationEnabled());

        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(indexBefore, indexAfter);
        assertEq(startBefore, startAfter);
        assertEq(durationBefore, durationAfter);
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.SUSPENDED));
    }

    /// @dev Test to ensure 'disableAutomation' does not change cycle state from FINISHED if automation is disabled and transition is in progress.
    function testDisableAutomationRetainsFinishedStateIfTransitionInProgress() public {
        // Register 2 USTs so transition requires processing both
        registerUst(diamondAddr, 2450); // task index 0
        registerUst(diamondAddr, 2450); // task index 1

        ( , uint64 startTime, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startTime + duration);

        // Move state to FINISHED
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.FINISHED));

        // Process only task 0 — transition is now in progress
        uint256[] memory partialTasks = new uint256[](1);
        partialTasks[0] = 0;

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(indexBefore + 1, partialTasks);

        // Cycle state is FINISHED (transition not yet complete)
        ( , , , LibCommon.CycleState stateAfterPartial) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateAfterPartial), uint8(LibCommon.CycleState.FINISHED));

        // Disable automation
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        assertFalse(ICoreFacet(diamondAddr).isAutomationEnabled());

        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(indexAfter, indexBefore);
        assertEq(startAfter, startBefore);
        assertEq(durationAfter, durationBefore);
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.FINISHED));
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

    /// @dev Test to ensure 'removeRegisteredTask' removes a UST when predicate validation fails and reduces the gasCommittedForNextCycle.
    function testRemoveRegisteredTasksForUST() public {
        // Register two USTs
        registerUst(diamondAddr, 2450);
        registerUst(diamondAddr, 2450);

        assertTrue(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertTrue(IRegistryFacet(diamondAddr).ifTaskExists(1));
        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 2);
        assertEq(IRegistryFacet(diamondAddr).getGasCommittedForNextCycle(), 200_000);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 120.2 ether);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 0 ether);
        assertEq(erc20Supra.balanceOf(diamondAddr), 122.2 ether);
        assertEq(erc20Supra.balanceOf(alice), 77.8 ether);

        uint256[] memory taskIndexes = new uint256[](2);
        taskIndexes[0] = 0;
        taskIndexes[1] = 1;
        uint64[] memory tasksUint64 = new uint64[](1);
        tasksUint64[0] = 0;
        string memory reason = "Predicate failed";

        processCycleTransition(diamondAddr, taskIndexes);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 6 ether);

        // Remove only task 0 due to predicate failure, cycle index is 2
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(2, tasksUint64[0], reason);

        // Verify only task 0 is removed; task 1 remains with its gas committed
        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertTrue(IRegistryFacet(diamondAddr).ifTaskExists(1));
        assertEq(IRegistryFacet(diamondAddr).totalTasks(), 1);
        assertEq(IRegistryFacet(diamondAddr).getGasCommittedForNextCycle(), 100_000);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 60.1 ether);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 3 ether);
        assertEq(erc20Supra.balanceOf(diamondAddr), 66.6 ether);
        assertEq(erc20Supra.balanceOf(alice), 133.4 ether);
    }

    /// @dev Test to ensure 'removeRegisteredTask' removes a GST when predicate validation fails and reduces the systemGasCommittedForNextCycle.
    function testRemoveRegisteredTasksForGST() public {
        // Register two GSTs
        registerGst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);

        assertTrue(IRegistryFacet(diamondAddr).ifSysTaskExists(0));
        assertTrue(IRegistryFacet(diamondAddr).ifSysTaskExists(1));
        assertEq(IRegistryFacet(diamondAddr).totalSystemTasks(), 2);
        assertEq(IRegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 200_000);

        uint256[] memory taskIndexes = new uint256[](2);
        taskIndexes[0] = 0;
        taskIndexes[1] = 1;
        uint64[] memory tasksUint64 = new uint64[](1);
        tasksUint64[0] = 0;
        string memory reason = "Predicate failed";

        processCycleTransition(diamondAddr, taskIndexes);

        // Remove only task 0 due to predicate failure
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(2, tasksUint64[0], reason);

        // Verify only task 0 is removed; task 1 remains with its gas committed
        assertFalse(IRegistryFacet(diamondAddr).ifSysTaskExists(0));
        assertTrue(IRegistryFacet(diamondAddr).ifSysTaskExists(1));
        assertEq(IRegistryFacet(diamondAddr).totalSystemTasks(), 1);
        assertEq(IRegistryFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 100_000);
    }

    /// @dev Test to ensure 'removeRegisteredTask' emits 'TaskRemovedBySystem' event.
    function testRemoveRegisteredTasksEmitsEvent() public {
        registerUst(diamondAddr, 2450);
        
        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;
        uint64[] memory tasksUint64 = new uint64[](1);
        tasksUint64[0] = 0;
        string memory reason = "Predicate failed";

        processCycleTransition(diamondAddr, taskIndexes);

        LibCommon.RemovedTask memory removedTask = LibCommon.RemovedTask(0, LibCommon.TaskType.UST, alice, keccak256("txHash"), "Predicate failed");

        vm.expectEmit(true, false, false, false);
        emit ICoreFacet.TaskRemovedBySystem(removedTask);

        // Remove task due to predicate failure
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(2, tasksUint64[0], reason);
    }

    /// @dev Test to ensure 'removeRegisteredTask' reverts if caller is not VM Signer.
    function testRemoveRegisteredTasksRevertsIfNotVmSigner() public {
        registerUst(diamondAddr, 2450);
        
        vm.expectRevert(LibUtils.CallerNotVmSigner.selector);

        uint64  taskIndex = 0;
        string memory reason = "Predicate failed";

        vm.prank(alice);
        ICoreFacet(diamondAddr).removeRegisteredTask(2, taskIndex, reason);
    }

    /// @dev Test to ensure 'removeRegisteredTask' reverts if cycle index is incorrect.
    function testRemoveRegisteredTasksRevertsIfCycleIndexIncorrect() public {
        registerUst(diamondAddr, 2450);

        vm.expectRevert(ICoreFacet.InvalidInputCycleIndex.selector);

        uint64  taskIndex = 0;
        string memory reason = "Predicate failed";

        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(2, taskIndex, reason);
    }

    /// @dev Test to ensure 'removeRegisteredTask' reverts if cycle index is incorrect.
    function testRemoveRegisteredTasksRevertsIfCycleIndexIncorrect2() public {
        registerUst(diamondAddr, 2450);

        vm.expectRevert(ICoreFacet.InvalidInputCycleIndex.selector);

        uint64  taskIndex = 0;
        string memory reason = "Predicate failed";

        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(0, taskIndex, reason);
    }

    /// @dev Test to ensure 'removeRegisteredTask' does nothing when automation is disabled.
    function testRemoveRegisteredTaskDoesNothingWhenAutomationDisabled() public {
        registerUst(diamondAddr, 2450);

        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        assertTrue(IRegistryFacet(diamondAddr).ifTaskExists(0));

        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(1, 0, "Predicate failed");

        assertTrue(IRegistryFacet(diamondAddr).ifTaskExists(0));
    }

    /// @notice Test to ensure removeRegisteredTask reverts with InsufficientBalanceForRefund if registry has insufficient balance.
    function testRemoveRegisteredTaskRevertsIfInsufficientBalance() public {
        registerUst(diamondAddr, 2450);

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;

        processCycleTransition(diamondAddr, taskIndexes);

        uint256 diamondBalance = erc20Supra.balanceOf(diamondAddr);
        vm.prank(diamondAddr);
        erc20Supra.transfer(address(0xdead), diamondBalance);
        assertEq(erc20Supra.balanceOf(diamondAddr), 0);

        vm.expectRevert(ICoreFacet.InsufficientBalanceForRefund.selector);

        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(2, 0, "Predicate failed");
    }

    /// @notice Test to ensure that when automation is disabled mid-transition (FINISHED, some tasks
    /// remaining), suspension is deferred until the transition completes and the new cycle starts.
    function testDisableAutomationDefersSuspensionUntilTransitionEnds() public {
        registerUst(diamondAddr, 2450);
        registerUst(diamondAddr, 2450);

        ( , uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 indexBefore, , , LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.FINISHED));

        // Process only task 0 — transition in progress
        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(indexBefore + 1, taskIndexes);

        ( , , , stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.FINISHED));

        // Disable automation — deferred because transition is in progress
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();
        assertFalse(ICoreFacet(diamondAddr).isAutomationEnabled());

        // Process task 1 — finalizes transition → new cycle STARTED → then SUSPENDED
        taskIndexes[0] = 1;

        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(indexBefore + 1, taskIndexes);

        (uint64 indexAfter, , , LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(indexAfter, indexBefore + 1);
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.SUSPENDED));
    }

    /// @dev Test to ensure 'getCycleStateDetails' returns correct cycle details.
    function testGetCycleStateDetails() public {
        registerUst(diamondAddr, 2450);

        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startBefore + durationBefore);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        LibCommon.CycleDetails memory details = ICoreFacet(diamondAddr).getCycleStateDetails();
        assertEq(details.index, indexBefore);
        assertEq(details.startTime, startBefore);
        assertEq(details.durationSecs, durationBefore);
        assertEq(uint8(details.state), uint8(LibCommon.CycleState.FINISHED));
        assertEq(details.nextTaskIndexPosition, 0);
        assertEq(details.expectedTasksToBeProcessed.length, 1);
        assertEq(details.expectedTasksToBeProcessed[0], 0);
    }

    /// @notice Test to ensure config buffer is applied when no tasks exist during cycle end, updating the cycle duration directly.
    function testConfigBufferAppliedWhenNoTasks() public {
        ( , uint64 startBefore, uint64 durationBefore, ) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(durationBefore, 1200);

        vm.prank(admin);
        IConfigFacet(diamondAddr).updateConfigBuffer(
            3600, 20_000_000, 0.5 ether, 1 ether, 50, 0.5 ether, 6, 400, 2400, 3600, 20_000_000, 100
        );

        vm.warp(startBefore + durationBefore);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 indexAfter, , uint64 durationAfter, LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(indexAfter, 2);
        assertEq(durationAfter, 2400);
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.STARTED));
    }

    /// @notice Test to ensure config buffer is applied after monitorCycleEnd + processTasks, resulting in STARTED state with the updated cycle duration.
    function testCycleTransitionAppliesConfigBuffer() public {
        registerUst(diamondAddr, 2450);

        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, ) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(durationBefore, 1200);

        vm.prank(admin);
        IConfigFacet(diamondAddr).updateConfigBuffer(
            3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2, 500, 2400, 3600, 5_000_000, 500
        );
        assertEq(IConfigFacet(diamondAddr).getConfigBuffer().cycleDurationSecs, 2400);

        vm.warp(startBefore + durationBefore);

        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        ICoreFacet(diamondAddr).processTasks(indexBefore + 1, tasks);
        vm.stopPrank();

        (uint64 indexAfter, , uint64 durationAfter, LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(indexAfter, indexBefore + 1);
        assertEq(durationAfter, 2400);
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.STARTED));
    }

    /// @notice Test to ensure 'processTasks' with an empty array returns early.
    function testProcessTasksWithEmptyArrayReturnsEarly() public {
        registerUst(diamondAddr, 2450);

        (uint64 index, uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);

        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        ( , , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.FINISHED));

        uint256[] memory empty;
        ICoreFacet(diamondAddr).processTasks(index + 1, empty);
        vm.stopPrank();

        ( , , , state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.FINISHED));
    }

    /// @notice Test to ensure that when buffer changes cycle duration, moveToReadyState resets transition state.
    function testMoveToReadyStateResetsTransitionStateOnDurationChange() public {
        registerUst(diamondAddr, 2450);

        (uint64 index, uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(duration, 1200);

        vm.prank(admin);
        IConfigFacet(diamondAddr).updateConfigBuffer(
            3600, 10_000_000, 0.001 ether, 0.002 ether, 50, 0.002 ether, 2, 500, 2400, 3600, 5_000_000, 500
        );

        vm.warp(start + duration);
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        ( , , , LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.SUSPENDED));

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(index, tasks);

        (uint64 refundDuration, uint128 automationFeePerSec) = ICoreFacet(diamondAddr).getTransitionInfo();
        assertEq(refundDuration, 0);
        assertEq(automationFeePerSec, 0);

        ( , , , LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.READY));
    }

    /// @notice Test to ensure partial task processing in FINISHED state keeps state FINISHED
    /// until the last task is processed, then transitions to STARTED.
    function testPartialTaskProcessingInFinishedState() public {
        registerUst(diamondAddr, 2450);
        registerUst(diamondAddr, 2450);

        (uint64 index, uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);
        
        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        ( , , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.FINISHED));

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        ICoreFacet(diamondAddr).processTasks(index + 1, tasks);

        ( , , , state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.FINISHED));

        tasks[0] = 1;
        ICoreFacet(diamondAddr).processTasks(index + 1, tasks);
        vm.stopPrank();

        ( , , , state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.STARTED));
    }

    /// @notice Test to ensure partial task processing in SUSPENDED state keeps state SUSPENDED
    /// until the last task is processed, then transitions to READY.
    function testPartialTaskProcessingInSuspendedState() public {
        registerUst(diamondAddr, 2450);
        registerUst(diamondAddr, 2450);

        (uint64 index, uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        ( , , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.SUSPENDED));

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        vm.startPrank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(index, tasks);

        ( , , , state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.SUSPENDED));

        tasks[0] = 1;
        ICoreFacet(diamondAddr).processTasks(index, tasks);
        vm.stopPrank();

        ( , , , state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.READY));
    }

    /// @notice Test to ensure an expired task is removed from the registry and 'RemovedTasks' is emitted during cycle transition.
    function testExpiredTaskRemovalInTransition() public {
        registerUst(diamondAddr, 2450);

        (uint64 index, uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);
        
        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        ( , , , LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.FINISHED));

        // Task is in registry before expiration
        assertEq(IRegistryFacet(diamondAddr).getTaskIdList().length, 1);

        // Move time forward past task expiration
        vm.warp(block.timestamp + 1250);

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;
        
        // Expect RemovedTasks event for the expired task
        uint64[] memory expectedRemoved = new uint64[](1);
        expectedRemoved[0] = 0;
        
        vm.expectEmit(true, false, false, false);
        emit ICoreFacet.RemovedTasks(expectedRemoved);

        ICoreFacet(diamondAddr).processTasks(index + 1, tasks);
        vm.stopPrank();

        // Task is removed from registry
        assertEq(IRegistryFacet(diamondAddr).getTaskIdList().length, 0);

        ( , , , LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.STARTED));
    }

    /// @notice Test to ensure a task is removed during transition when the owner does not have enough
    /// allowance for the automation fee. The deposit is unlocked and forfeited to the registry.
    function testInsufficientAllowanceDuringTransitionRemovesTask() public {
        registerUst(diamondAddr, 2450);
        uint256 balanceBefore = erc20Supra.balanceOf(alice);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 60.1 ether);

        // Revoke alice's allowance for the AutomationRegistry
        vm.prank(alice);
        erc20Supra.approve(diamondAddr, 0);

        ( , uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        (uint64 index, , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.FINISHED));

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        vm.expectEmit(true, true, true, true);
        emit ICoreFacet.TaskCancelledInsufficentBalanceAllowance(0, alice, 3 ether, 38.9 ether, 0, keccak256("txHash"));

        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(index + 1, tasks);

        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(erc20Supra.balanceOf(alice), balanceBefore);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 0);
    }

    /// @notice Test to ensure enabling automation during SUSPENDED state makes the finalised transition go to STARTED.
    function testEnableAutomationDuringSuspendedFinalizesToStarted() public {
        registerUst(diamondAddr, 2450);

        (uint64 index, uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        ( , , , LibCommon.CycleState stateBefore) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateBefore), uint8(LibCommon.CycleState.SUSPENDED));

        vm.prank(admin);
        ICoreFacet(diamondAddr).enableAutomation();

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(index, tasks);

        ( , , , LibCommon.CycleState stateAfter) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.STARTED));
    }

    /// @dev refundTaskFees refunds the full cycle locked fee when the task's active timeframe
    /// spans beyond the refund duration. With 2450s expiry, taskActiveTimeframe=1250s which
    /// exceeds refundDuration=1200s, so actualFeeTimeframe is capped at 1200s (full cycle).
    /// Result: all 3 ether locked fee is refunded
    function testRefundTaskFeesOnSuspendForActiveTaskRefundsFullCycleFees() public {
        registerUst(diamondAddr, 2450);

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;

        processCycleTransition(diamondAddr, taskIndexes);

        (uint64 index, , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.STARTED));

        // State before refund
        assertEq(erc20Supra.balanceOf(alice), 35.9 ether);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 3 ether);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 60.1 ether);

        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        ( , , , state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.SUSPENDED));

        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(index, taskIndexes);

        // State after refund
        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(erc20Supra.balanceOf(alice), 99 ether);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 0);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 0);
    }

    /// @dev refundTaskFees refunds only a partial locked fee when the task expires early in
    /// the cycle. With 1250s expiry, taskActiveTimeframe=50s which is less than
    /// refundDuration=1200s, so actualFeeTimeframe=50s. Only the fee for 50s (0.125 ether) is refunded.
    function testRefundTaskFeesOnSuspendForActiveTaskRefundsPartialCycleFees() public {
        registerUst(diamondAddr, 1250);

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;

        processCycleTransition(diamondAddr, taskIndexes);

        (uint64 index, , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.STARTED));

        // State before refund
        assertEq(erc20Supra.balanceOf(alice), 35.9 ether);
        assertEq(IRegistryFacet(diamondAddr).getCycleLockedFees(), 3 ether);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 60.1 ether);

        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        ( , , , state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.SUSPENDED));

        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(index, taskIndexes);

        // State after refund: only 0.125 ether of the 3 ether locked fee is refunded
        // (50s worth out of 1200s cycle).
        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(erc20Supra.balanceOf(alice), 96.125 ether);
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), 0);
    }

    /// @notice Test to ensure safeRefund emits ErrorInsufficientBalanceToRefund when the registry's balance is insufficient
    /// to process refund, and that the task is still removed.
    function testSafeRefundEmitsErrorInsufficientBalanceToRefundIfInsufficientBalance() public {
        registerUst(diamondAddr, 1250);
        assertTrue(IRegistryFacet(diamondAddr).ifTaskExists(0));

        uint256[] memory taskIndexes = new uint256[](1);
        taskIndexes[0] = 0;

        processCycleTransition(diamondAddr, taskIndexes);

        uint256 diamondBalance = erc20Supra.balanceOf(diamondAddr);
        vm.prank(diamondAddr);
        erc20Supra.transfer(bob, diamondBalance);
        assertEq(erc20Supra.balanceOf(diamondAddr), 0);

        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        ( , , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.SUSPENDED));

        vm.expectEmit(true, true, true, true);
        emit IRegistryFacet.ErrorInsufficientBalanceToRefund(0, alice, 1, 0.125 ether);

        vm.expectEmit(true, true, true, true);
        emit IRegistryFacet.ErrorInsufficientBalanceToRefund(0, alice, 0, 60.1 ether);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(2, taskIndexes);        
        assertFalse(IRegistryFacet(diamondAddr).ifTaskExists(0));
    }

    /// @dev Test to ensure the congestion fee uses the proportional surplus formula when
    /// threshold usage exceeds congestion threshold percentage but not 100%.
    function testRegisterWhenGasOccupancyIsAboveThresholdButBelowFullCapacity() public {
        uint256 depositAmount = 451 ether;

        // Congestion multiplier is inactive below threshold
        uint128 baseMultiplier = IRegistryFacet(diamondAddr).calculateAutomationFeeMultiplierForCommittedOccupancy(100_000);
        assertEq(baseMultiplier, 0.5 ether, "sub-threshold should use base fee only");

        // Congestion multiplier activates above 50%
        uint128 congestedMultiplier = IRegistryFacet(diamondAddr).calculateAutomationFeeMultiplierForCommittedOccupancy(11_000_000);
        assertEq(congestedMultiplier, 0.67004782 ether, "congestion should raise fee above base");

        // Estimated fee
        uint128 estimatedFee = IRegistryFacet(diamondAddr).estimateAutomationFee(11_000_000);
        assertEq(estimatedFee, 442.2315612 ether);

        vm.startPrank(alice);
        vm.deal(alice, depositAmount);
        erc20SupraHandler.deposit{value: depositAmount}();
        erc20Supra.approve(diamondAddr, type(uint256).max);

        uint128 cap = 450 ether;

        IRegistryFacet(diamondAddr).register(
            createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, uint128(100))),
            createPredicate(diamondAddr),
            uint64(block.timestamp + 2450),
            uint128(11_000_000),
            uint128(4 gwei),
            uint128(cap),
            0,
            new bytes[](0)
        );
        vm.stopPrank();

        assertTrue(IRegistryFacet(diamondAddr).ifTaskExists(0));
        assertEq(IRegistryFacet(diamondAddr).getTotalDepositedAutomationFees(), cap, "automation fee not deposited");
        assertEq(erc20Supra.balanceOf(alice), 0, "balance should be 0 after spending all [450 ether + 1 ether as flat reg fee]");
    }

    /// @dev Test to ensure registration succeeds when automation and congestion base fees are zero. 
    /// The fee multiplier and estimated fee are both 0 regardless of gas occupancy. 
    /// Only the flat registration fee and the user's cap are deducted from the balance.
    function testRegisterWithZeroBaseFee() public {
        address customRegistry = deployCustomRegistry();

        // With zero base fees, multiplier and estimated fee should be 0
        uint128 multiplier = IRegistryFacet(customRegistry).calculateAutomationFeeMultiplierForCommittedOccupancy(100_000);
        assertEq(multiplier, 0);
        uint128 estimatedFee = IRegistryFacet(customRegistry).estimateAutomationFee(100_000);
        assertEq(estimatedFee, 0);
        
        registerUst(customRegistry, 2450);

        assertTrue(IRegistryFacet(customRegistry).ifTaskExists(0));
        // Only flat reg fee(1 ether) and automation fee cap(60.1 ether) is deducted since estimated automation fee is 0
        assertEq(erc20Supra.balanceOf(alice), 38.9 ether);
    }

    /// @dev Test to ensure calculateTaskFee returns 0 when the automationBaseFeeWeiPerSec is 0.
    /// This is exercised during a cycle transition: calculateTaskFee exits early with 0 fee,
    /// no cycle fees are locked, and the task activates normally.
    function testCalculateTaskFeeReturnsZeroWhenBaseFeeIsZero() public {
        address customRegistry = deployCustomRegistry();
        registerUst(customRegistry, 2450);

        // Perform cycle transition
        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;
        processCycleTransition(customRegistry, tasks);

        // With zero fee, the cycle locked fee should be 0
        assertEq(IRegistryFacet(customRegistry).getCycleLockedFees(), 0);

        // Task should be active
        assertTrue(IRegistryFacet(customRegistry).ifTaskExists(0));
        assertEq(IRegistryFacet(customRegistry).getActiveTaskIds().length, 1);
        assertEq(IRegistryFacet(customRegistry).getActiveTaskIds()[0], 0);
    }
}
