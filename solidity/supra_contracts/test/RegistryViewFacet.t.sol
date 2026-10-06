// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {IRegistryViewFacet} from "../src/interfaces/IRegistryViewFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {TaskMetadata} from "../src/libraries/LibAppStorage.sol";

/// @notice Tests for the 25 views split out of RegistryFacet into RegistryViewFacet
/// (Entropy-Foundation/smr-moonshot#4101). The four fee-estimating views and
/// `isAuthorizedSubmitter`, which stayed on RegistryFacet, are still tested in
/// RegistryFacet.t.sol.
contract RegistryViewFacetTest is BaseDiamondTest {

    /// @dev Test to ensure 'getTaskIdList' returns correct task IDs.
    function testGetTaskIdList() public {
        registerUst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);

        uint256[] memory taskIds = IRegistryViewFacet(diamondAddr).getTaskIdList();
        assertEq(taskIds.length, 2);
        assertEq(taskIds[0], 0);
        assertEq(taskIds[1], 1);
    }

    /// @dev Test to ensure 'getSystemTaskIds' returns correct system task IDs.
    function testGetSystemTaskIds() public {
        registerGst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);

        uint256[] memory sysTaskIds = IRegistryViewFacet(diamondAddr).getSystemTaskIds();
        assertEq(sysTaskIds.length, 2);
        assertEq(sysTaskIds[0], 0);
        assertEq(sysTaskIds[1], 1);
    }

    /// @dev Test to ensure 'getTaskOwner' returns correct owner for an existing task.
    function testGetTaskOwner() public {
        registerUst(diamondAddr, 2450);

        address owner = IRegistryViewFacet(diamondAddr).getTaskOwner(0);
        assertEq(owner, alice);
    }

    /// @dev Test to ensure 'getTotalActiveTasks' returns the correct count of active tasks.
    function testGetTotalActiveTasks() public {
        registerUst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);
        
        uint64[] memory taskIndexes = new uint64[](2);
        taskIndexes[0] = 0;
        taskIndexes[1] = 1;

        processCycleTransition(diamondAddr, taskIndexes);

        assertEq(IRegistryViewFacet(diamondAddr).getTotalActiveTasks(), 2);
    }

    /// @dev Test to ensure 'getTotalActiveTasks' returns zero when no active tasks.
    function testGetTotalActiveTasksZero() public view {
        assertEq(IRegistryViewFacet(diamondAddr).getTotalActiveTasks(), 0);
    }

    /// @dev Test to ensure 'getActiveTaskIds' returns correct active task IDs.
    function testGetActiveTaskIds() public {
        registerUst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);

        uint64[] memory taskIndexes = new uint64[](2);
        taskIndexes[0] = 0;
        taskIndexes[1] = 1;

        processCycleTransition(diamondAddr, taskIndexes);

        uint64[] memory activeIds = IRegistryViewFacet(diamondAddr).getActiveTaskIds();
        assertEq(activeIds.length, 2);
        assertEq(activeIds[0], 0);
        assertEq(activeIds[1], 1);
    }

    /// @dev Test to ensure 'getActiveTaskIds' returns empty array when no tasks are active.
    function testGetActiveTaskIdsEmpty() public view {
        assertEq(IRegistryViewFacet(diamondAddr).getActiveTaskIds().length, 0);
    }

    /// @dev Test to ensure 'getTotalLockedBalance' returns the correct locked balance.
    function testGetTotalLockedBalance() public {
        registerUst(diamondAddr, 2450);

        assertEq(IRegistryViewFacet(diamondAddr).getTotalLockedBalance(), 60.1 ether);
    }

    /// @dev Test to ensure 'hasActiveUserTask' returns true for an active task.
    function testHasActiveUserTask() public {
        registerUst(diamondAddr, 2450);

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        processCycleTransition(diamondAddr, taskIndexes);

        assertTrue(IRegistryViewFacet(diamondAddr).hasActiveUserTask(alice, 0));
    }

    /// @dev Test to ensure 'hasActiveUserTask' returns false for a pending or non-existent task.
    function testHasActiveUserTaskForPendingOrNonExistent() public {
        registerUst(diamondAddr, 2450);

        assertFalse(IRegistryViewFacet(diamondAddr).hasActiveUserTask(alice, 0));
        assertFalse(IRegistryViewFacet(diamondAddr).hasActiveUserTask(alice, 99));
    }

    /// @dev Test to ensure 'hasActiveSystemTask' returns true for an active system task.
    function testHasActiveSystemTask() public {
        registerGst(diamondAddr, 2450);

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;

        processCycleTransition(diamondAddr, taskIndexes);

        assertTrue(IRegistryViewFacet(diamondAddr).hasActiveSystemTask(bob, 0));
    }

    /// @dev Test to ensure 'hasActiveSystemTask' returns false for a pending or non-existent system task.
    function testHasActiveSystemTaskForPendingOrNonExistent() public {
        registerGst(diamondAddr, 2450);

        assertFalse(IRegistryViewFacet(diamondAddr).hasActiveSystemTask(bob, 0));
        assertFalse(IRegistryViewFacet(diamondAddr).hasActiveSystemTask(bob, 99));
    }

    /// @dev Test to ensure 'hasActiveTaskOfType' returns correct values.
    function testHasActiveTaskOfType() public {
        registerUst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);

        uint64[] memory taskIndexes = new uint64[](2);
        taskIndexes[0] = 0;
        taskIndexes[1] = 1;

        processCycleTransition(diamondAddr, taskIndexes);

        assertTrue(IRegistryViewFacet(diamondAddr).hasActiveTaskOfType(alice, 0, LibCommon.TaskType.UST));
        assertTrue(IRegistryViewFacet(diamondAddr).hasActiveTaskOfType(bob, 1, LibCommon.TaskType.GST));
    }

    /// @dev Test to ensure 'hasActiveTaskOfType' returns false for pending or non-existent task.
    function testHasActiveTaskOfTypeForPendingOrNonExistent() public {
        registerUst(diamondAddr, 2450);

        assertFalse(IRegistryViewFacet(diamondAddr).hasActiveTaskOfType(alice, 0, LibCommon.TaskType.UST));
        assertFalse(IRegistryViewFacet(diamondAddr).hasActiveTaskOfType(alice, 99, LibCommon.TaskType.UST));
    }

    /// @dev Test to ensure 'getTaskDetailsBulk' returns correct details for existing and non-existing tasks.
    function testGetTaskDetailsBulk() public {
        registerUst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);

        uint64[] memory taskIndexes = new uint64[](3);
        taskIndexes[0] = 0;
        taskIndexes[1] = 1;
        taskIndexes[2] = 99;

        TaskMetadata[] memory details = IRegistryViewFacet(diamondAddr).getTaskDetailsBulk(taskIndexes);
        assertEq(details.length, 2);
        assertEq(details[0].taskIndex, 0);
        assertEq(details[0].owner, alice);
        assertEq(details[1].taskIndex, 1);
        assertEq(details[1].owner, bob);
    }
}
