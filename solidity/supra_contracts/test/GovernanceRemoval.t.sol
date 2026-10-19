// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {ConstructorTaskRegistrant} from "./TaskRegistrant.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {IRegistryViewFacet} from "../src/interfaces/IRegistryViewFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibDiamond} from "../src/libraries/LibDiamond.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";

/// @notice ConfigFacet.removeTasks: the registry owner removes any task, and the task's owner is
/// refunded exactly what stopping the task would have refunded (#4636).
contract GovernanceRemovalTest is BaseDiamondTest {
    uint64 constant TASK_DURATION = 1250;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Helpers :::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    function singleTask(uint64 _taskIndex) internal pure returns (uint64[] memory taskIndexes) {
        taskIndexes = new uint64[](1);
        taskIndexes[0] = _taskIndex;
    }

    function removeAsRegistryOwner(uint64[] memory _taskIndexes) internal {
        vm.prank(admin);
        IConfigFacet(diamondAddr).removeTasks(_taskIndexes);
    }

    function committedGas(bool _isGst) internal view returns (uint256) {
        return _isGst
            ? IRegistryViewFacet(diamondAddr).getSystemGasCommittedForNextCycle()
            : IRegistryViewFacet(diamondAddr).getGasCommittedForNextCycle();
    }

    /// @dev Stops `_taskIndex` as `_owner` and, from the same state, removes it as the registry
    /// owner; asserts both leave the owner, the registry balance and the committed gas the same.
    function assertRemovalMatchesStop(uint64 _taskIndex, address _owner, bool _isGst) internal {
        uint256 ownerBefore = wsupra.balanceOf(_owner);
        uint256 snapshot = vm.snapshotState();

        vm.prank(_owner);
        if (_isGst) {
            IRegistryFacet(diamondAddr).stopSystemTasks(singleTask(_taskIndex));
        } else {
            IRegistryFacet(diamondAddr).stopTasks(singleTask(_taskIndex));
        }
        uint256 ownerAfterStop = wsupra.balanceOf(_owner);
        uint256 registryAfterStop = wsupra.balanceOf(diamondAddr);
        uint256 committedAfterStop = committedGas(_isGst);

        vm.revertToState(snapshot);
        removeAsRegistryOwner(singleTask(_taskIndex));

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(_taskIndex));
        assertEq(wsupra.balanceOf(_owner), ownerAfterStop, "owner refund differs from a stop");
        assertEq(wsupra.balanceOf(diamondAddr), registryAfterStop, "registry balance differs from a stop");
        assertEq(committedGas(_isGst), committedAfterStop, "committed gas differs from a stop");
        if (_isGst) {
            assertEq(ownerAfterStop, ownerBefore, "a GST is refunded nothing");
        }
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Refunds :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev An ACTIVE UST removed by the registry owner refunds its owner the whole deposit and
    /// half the remaining cycle fee, the amounts of RegistryFacetTest.testStopTasks, and emits
    /// TaskRemovedByGovernance.
    function testRemoveTasksRefundsAnActiveUstAsAStop() public {
        registerUst(diamondAddr, TASK_DURATION);
        processCycleTransition(diamondAddr, singleTask(0));
        uint256 aliceBefore = wsupra.balanceOf(alice);

        vm.expectEmit(diamondAddr);
        emit IConfigFacet.TaskRemovedByGovernance(
            0, alice, LibCommon.TaskType.UST, keccak256("txHash"), 60.1 ether, 0.0625 ether
        );
        removeAsRegistryOwner(singleTask(0));

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
        assertEq(IRegistryViewFacet(diamondAddr).getTasksByAddress(alice).length, 0);
        assertEq(IRegistryViewFacet(diamondAddr).getGasCommittedForNextCycle(), 0);
        assertEq(IRegistryViewFacet(diamondAddr).getTotalDepositedAutomationFees(), 0);
        assertEq(wsupra.balanceOf(alice) - aliceBefore, 60.1625 ether);
    }

    function testRemoveTasksMatchesStopForAnActiveUst() public {
        registerUst(diamondAddr, TASK_DURATION);
        processCycleTransition(diamondAddr, singleTask(0));
        assertRemovalMatchesStop(0, alice, false);
    }

    /// @dev A PENDING UST refunds half its deposit, as a stop does.
    function testRemoveTasksMatchesStopForAPendingUst() public {
        registerUst(diamondAddr, TASK_DURATION);
        assertRemovalMatchesStop(0, alice, false);
    }

    /// @dev A CANCELLED UST no longer counts towards the next cycle's committed gas.
    function testRemoveTasksMatchesStopForACancelledUst() public {
        registerUst(diamondAddr, TASK_DURATION);
        processCycleTransition(diamondAddr, singleTask(0));
        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelTasks(singleTask(0));
        assertRemovalMatchesStop(0, alice, false);
    }

    /// @dev A GST is removed without any token movement, and its system gas commitment is released.
    function testRemoveTasksRemovesAGstWithoutARefund() public {
        registerGst(diamondAddr, TASK_DURATION);
        processCycleTransition(diamondAddr, singleTask(0));
        assertRemovalMatchesStop(0, bob, true);
        assertFalse(IRegistryViewFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(IRegistryViewFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 0);
    }

    /// @dev A UST and a GST in one batch are both removed, each with its own event.
    function testRemoveTasksRemovesUstAndGstInOneBatch() public {
        registerUst(diamondAddr, TASK_DURATION);
        registerGst(diamondAddr, TASK_DURATION);
        uint64[] memory taskIndexes = new uint64[](2);
        taskIndexes[0] = 0;
        taskIndexes[1] = 1;

        vm.recordLogs();
        removeAsRegistryOwner(taskIndexes);

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(1));
        assertEq(countLogs(vm.getRecordedLogs(), IConfigFacet.TaskRemovedByGovernance.selector), 2);
    }

    /// @dev A task owned by a contract that has no function to cancel or stop it can only be
    /// removed by the registry owner; the refund goes to the contract.
    function testRemoveTasksRemovesATaskWhoseContractOwnerCannotStopIt() public {
        vm.deal(address(this), 200 ether);
        ConstructorTaskRegistrant registrant = new ConstructorTaskRegistrant{value: 200 ether}(
            diamondAddr,
            address(wsupra),
            createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100)),
            createPredicate(diamondAddr),
            uint64(block.timestamp + TASK_DURATION),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether)
        );
        processCycleTransition(diamondAddr, singleTask(0));
        uint256 registrantBefore = wsupra.balanceOf(address(registrant));

        removeAsRegistryOwner(singleTask(0));

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
        assertEq(wsupra.balanceOf(address(registrant)) - registrantBefore, 60.1625 ether);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Guards :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Only the registry owner can call removeTasks; a task's own owner cannot.
    function testRemoveTasksRevertsIfCallerIsNotTheRegistryOwner() public {
        registerUst(diamondAddr, TASK_DURATION);

        vm.prank(alice);
        vm.expectRevert(LibDiamond.MustBeContractOwner.selector);
        IConfigFacet(diamondAddr).removeTasks(singleTask(0));
        assertTrue(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
    }

    /// @dev An index with no task is skipped and reported by TaskRemovalByGovernanceSkipped; the
    /// rest of the batch is removed.
    function testRemoveTasksSkipsAMissingIndex() public {
        registerUst(diamondAddr, TASK_DURATION);
        uint64[] memory taskIndexes = new uint64[](2);
        taskIndexes[0] = 7;
        taskIndexes[1] = 0;
        vm.expectEmit(diamondAddr);
        emit IConfigFacet.TaskRemovalByGovernanceSkipped(7);

        vm.recordLogs();
        removeAsRegistryOwner(taskIndexes);

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(countLogs(logs, IConfigFacet.TaskRemovedByGovernance.selector), 1);
        assertEq(countLogs(logs, IConfigFacet.TaskRemovalByGovernanceSkipped.selector), 1);
    }

    function testRemoveTasksRevertsIfInputIsEmpty() public {
        vm.prank(admin);
        vm.expectRevert(IRegistryFacet.TaskIndexesCannotBeEmpty.selector);
        IConfigFacet(diamondAddr).removeTasks(new uint64[](0));
    }

    function testRemoveTasksRevertsDuringACycleTransition() public {
        registerUst(diamondAddr, TASK_DURATION);
        endCycleAsVmSigner(diamondAddr);

        vm.prank(admin);
        vm.expectRevert(IRegistryFacet.CycleTransitionInProgress.selector);
        IConfigFacet(diamondAddr).removeTasks(singleTask(0));
    }

    function testRemoveTasksRevertsIfAutomationIsDisabled() public {
        registerUst(diamondAddr, TASK_DURATION);
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        vm.prank(admin);
        vm.expectRevert(IRegistryFacet.AutomationNotEnabled.selector);
        IConfigFacet(diamondAddr).removeTasks(singleTask(0));
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::: Runtime removal of a removed task ::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev A runtime removal record with reason ERROR for a task the registry owner has already
    /// removed in the same block is a no-op, so the record does not revert; it emits only
    /// TaskRemovalSkipped.
    function testAnErrorRemovalOfAGovernanceRemovedTaskIsANoOp() public {
        registerUst(diamondAddr, TASK_DURATION);
        processCycleTransition(diamondAddr, singleTask(0));
        (uint64 cycleIndex,,,) = ICoreFacet(diamondAddr).getCycleInfo();
        removeAsRegistryOwner(singleTask(0));
        uint256 registryBefore = wsupra.balanceOf(diamondAddr);
        vm.expectEmit(diamondAddr);
        emit ICoreFacet.TaskRemovalSkipped(0, LibCommon.TaskRemovalReason.ERROR);

        vm.recordLogs();
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(cycleIndex, 0, LibCommon.TaskRemovalReason.ERROR, "Predicate failed");

        assertEq(vm.getRecordedLogs().length, 1);
        assertEq(wsupra.balanceOf(diamondAddr), registryBefore);
    }

    function countLogs(Vm.Log[] memory _logs, bytes32 _topic0) internal pure returns (uint256 count) {
        for (uint256 i; i < _logs.length; i++) {
            if (_logs[i].topics.length > 0 && _logs[i].topics[0] == _topic0) { count++; }
        }
    }
}
