// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {ICoreViewFacet} from "../src/interfaces/ICoreViewFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {IRegistryViewFacet} from "../src/interfaces/IRegistryViewFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";

/// @notice Behaviour of the registry's ordered task list (`RegistryState.orderedTaskIds`) under
///         `monitorCycleEnd`'s per-block compaction (LibCore.compactOrderedTaskIdsIfSparse,
///         Entropy-Foundation/smr-moonshot#4920).
///
/// The rule under test: in every block of a STARTED cycle whose end has not been reached,
/// `monitorCycleEnd` rewrites the list to the ascending live task IDs when at least a quarter of
/// its entries are removed tasks, clears it when no task is live, and otherwise leaves it as it is.
/// After any such call, the list therefore either equals the live list or has fewer than a quarter
/// removed entries. Outside STARTED the call does nothing to the list. The empty-registry branches
/// of a cycle end and of a suspension clear it as well, so every cycle starts from the live list.
///
/// Everything runs against a real diamond deployed by BaseDiamondTest, with no mocks beyond the
/// precompiles Forge's EVM does not have. The list has no view, so it is read from storage
/// (BaseDiamondTest.readOrderedTaskIds).
contract OrderedTaskIdsCompactionTest is BaseDiamondTest {
    /// @dev Task duration used by every registration here: one day, far beyond the 1,200 s test
    ///      cycle, so no task expires while a test runs unless the test sets a shorter one.
    uint64 constant TASK_DURATION = 1 days;

    /// @dev ID the next registration on `diamondAddr` will receive. Task IDs are assigned from 0
    ///      upwards by the registry (RegistryState.currentIndex), and each test starts from a fresh
    ///      diamond, so the test can track them without a view.
    uint64 nextTaskId;

    // ────────────────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Gives alice enough wrapped SUPRA for `_n` registrations and approves the diamond.
    ///      Each registration takes the flat fee (1 ether in the default test parameters) and
    ///      locks the automation fee cap (60.1 ether) as the deposit, so 62 ether per task covers
    ///      it with a margin.
    function _fundAlice(uint256 _n) internal {
        uint256 amount = _n * 62 ether;
        vm.deal(alice, amount);
        vm.startPrank(alice);
        wsupra.deposit{value: amount}();
        wsupra.approve(diamondAddr, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Registers one user task as alice with `_duration` seconds to expiry and returns its ID.
    ///      Alice must have been funded (`_fundAlice`).
    function _registerUst(uint64 _duration) internal returns (uint64 taskId) {
        bytes[] memory auxData;
        taskId = nextTaskId;
        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            createPayload(0, address(wsupra), abi.encodeCall(wsupra.withdraw, 100)),
            createPredicate(diamondAddr),
            uint64(block.timestamp + _duration),
            uint128(100_000),       // maxGasAmount
            uint128(4 gwei),        // gasPriceCap
            uint128(60.1 ether),    // automationFeeCapForCycle
            2,                      // priority
            auxData
        );
        nextTaskId++;
    }

    /// @dev Registers `_n` user tasks with the default duration and returns their IDs.
    function _registerUsts(uint256 _n) internal returns (uint64[] memory ids) {
        ids = new uint64[](_n);
        for (uint256 i; i < _n; i++) {
            ids[i] = _registerUst(TASK_DURATION);
        }
    }

    /// @dev Moves to the next block and runs its prologue (monitorCycleEnd), as the chain does
    ///      before any transaction of a block. Every test here advances blocks through this
    ///      helper, so the list is always seen in the states the chain produces. A block is 1 s,
    ///      far within the 1,200 s test cycle.
    function _nextBlockWithPrologue() internal {
        nextBlock();
        _monitor();
    }

    /// @dev Cancels alice's PENDING tasks `_taskIds` in the current block, which removes them from
    ///      the registry. The tasks must have been registered in an earlier block
    ///      (LibRegistry.requireRegisteredBeforeThisBlock).
    function _cancelNow(uint64[] memory _taskIds) internal {
        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelTasks(_taskIds);
    }

    /// @dev Moves to the next block, runs its prologue, then cancels `_taskIds` there. The block
    ///      changes first because an owner cannot remove a task in the block it was registered in.
    function _cancel(uint64[] memory _taskIds) internal {
        _nextBlockWithPrologue();
        _cancelNow(_taskIds);
    }

    /// @dev Cancels the single task `_id`.
    function _cancelOne(uint64 _id) internal {
        _cancel(singleTask(_id));
    }

    /// @dev Calls monitorCycleEnd as the VM signer, as BlockMeta's prologue does, at the current
    ///      block time (so within the cycle unless the test warped past its end). Tests call it
    ///      through _nextBlockWithPrologue; a direct call is a second prologue in the same block.
    function _monitor() internal {
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();
    }

    /// @dev Asserts what the registry guarantees about the list after a monitorCycleEnd in a
    ///      STARTED cycle:
    ///        - it is strictly ascending;
    ///        - its live entries are exactly the registry's live tasks (taskIdList), each once;
    ///        - it equals the live list, or fewer than a quarter of its entries are removed tasks
    ///          (4 * live > 3 * length).
    ///      Strictly ascending rules out duplicates, so "every entry counted live exists, and the
    ///      count equals taskIdList's length" is set equality with the live tasks.
    function _assertListMatchesRegistry(string memory _context) internal view {
        uint64[] memory list = readOrderedTaskIds(diamondAddr);
        uint256 live = IRegistryViewFacet(diamondAddr).getTaskIdList().length;

        uint256 liveInList;
        for (uint256 i; i < list.length; i++) {
            if (i > 0) {
                assertLt(list[i - 1], list[i], string.concat(_context, ": list not strictly ascending"));
            }
            if (IRegistryViewFacet(diamondAddr).ifTaskExists(list[i])) {
                liveInList++;
            }
        }
        assertEq(liveInList, live, string.concat(_context, ": live entries differ from taskIdList"));
        assertTrue(
            list.length == live || 4 * live > 3 * list.length,
            string.concat(_context, ": a quarter or more of the list is removed tasks after monitorCycleEnd")
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    // Threshold
    // ────────────────────────────────────────────────────────────────────────

    /// @notice With no task removed the list is left as registered.
    function testMonitorCycleEnd_LeavesListWithNoRemovedTask() public {
        _fundAlice(3);
        _registerUsts(3);

        _nextBlockWithPrologue();

        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(0, 1, 2), "list after monitorCycleEnd");
    }

    /// @notice One removed entry out of five (20 %) is below the quarter, so the list is kept.
    function testMonitorCycleEnd_KeepsListBelowAQuarterRemoved() public {
        _fundAlice(5);
        _registerUsts(5);
        _cancelOne(0);

        _nextBlockWithPrologue();

        // The removed task 0 stays in the list: 4 live out of 5 entries is above three quarters.
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(0, 1, 2, 3, 4), "list after monitorCycleEnd");
        _assertListMatchesRegistry("below a quarter");
    }

    /// @notice Exactly a quarter removed (one of four) compacts the list: the threshold is inclusive.
    function testMonitorCycleEnd_CompactsAtExactlyAQuarterRemoved() public {
        _fundAlice(4);
        _registerUsts(4);
        _cancelOne(1);

        _nextBlockWithPrologue();

        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(0, 2, 3), "list after monitorCycleEnd");
    }

    /// @notice A removed entry kept below the threshold is dropped once later removals reach it.
    function testMonitorCycleEnd_CompactsOnceLaterRemovalsReachTheThreshold() public {
        _fundAlice(5);
        _registerUsts(5);
        _cancelOne(0);
        _nextBlockWithPrologue();
        assertEq(readOrderedTaskIds(diamondAddr).length, 5, "kept below the threshold");

        _cancelOne(3);
        _nextBlockWithPrologue();

        // 3 live out of 5 entries: two fifths removed.
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(1, 2, 4), "list after the second removal");
    }

    // ────────────────────────────────────────────────────────────────────────
    // Order and content
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Compaction keeps the survivors in ascending order, and registrations made after a
    ///         compaction are appended behind them, so the list stays ascending without a sort.
    function testMonitorCycleEnd_CompactionKeepsSurvivorsAscending() public {
        _fundAlice(10);
        _registerUsts(8);                       // 0..7
        uint64[] memory toCancel = new uint64[](3);
        toCancel[0] = 1; toCancel[1] = 3; toCancel[2] = 6;
        _cancel(toCancel);

        _nextBlockWithPrologue();
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(0, 2, 4, 5, 7), "first compaction");

        _registerUsts(2);                       // 8, 9, after this block's compaction
        toCancel[0] = 0; toCancel[1] = 2; toCancel[2] = 4;
        _cancel(toCancel);
        _nextBlockWithPrologue();

        // 4 live (5, 7, 8, 9) out of 7 entries.
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(5, 7, 8, 9), "second compaction");
        _assertListMatchesRegistry("after two compactions");
    }

    /// @notice With no live task left, the list is cleared.
    function testMonitorCycleEnd_ClearsListWhenNoTaskIsLive() public {
        _fundAlice(2);
        _cancel(_registerUsts(2));

        _nextBlockWithPrologue();

        assertEq(readOrderedTaskIds(diamondAddr).length, 0, "list after monitorCycleEnd");
    }

    /// @notice The cycle-end scan after a compaction sees only the live tasks, in order.
    function testMonitorCycleEnd_CycleEndAfterCompactionExpectsLiveTasks() public {
        _fundAlice(6);
        _registerUsts(6);                       // 0..5
        uint64[] memory toCancel = new uint64[](3);
        toCancel[0] = 0; toCancel[1] = 2; toCancel[2] = 4;
        _cancel(toCancel);
        _nextBlockWithPrologue();

        endCycleAsVmSigner(diamondAddr);

        LibCommon.CycleDetails memory details = ICoreViewFacet(diamondAddr).getCycleStateDetails();
        assertEq(uint8(details.state), uint8(LibCommon.CycleState.FINISHED), "cycle state");
        assertEqUint64Array(details.expectedTasksToBeProcessed, uint64Array(1, 3, 5), "expected tasks");
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(1, 3, 5), "list at the cycle end");
    }

    /// @notice With no task removed, the list is already the live list: the cycle end expects
    ///         every registered task, in order, and leaves the list as registered
    ///         (buildAliveOrderedTaskIds returns it without filtering).
    function testMonitorCycleEnd_CycleEndWithNoRemovalExpectsEveryTask() public {
        _fundAlice(4);
        _registerUsts(4);                       // 0..3

        endCycleAsVmSigner(diamondAddr);

        LibCommon.CycleDetails memory details = ICoreViewFacet(diamondAddr).getCycleStateDetails();
        assertEq(uint8(details.state), uint8(LibCommon.CycleState.FINISHED), "cycle state");
        assertEqUint64Array(details.expectedTasksToBeProcessed, uint64Array(0, 1, 2, 3), "expected tasks");
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(0, 1, 2, 3), "list at the cycle end");
    }

    /// @notice Removed entries the per-block compaction kept (below a quarter) are filtered out at
    ///         the cycle end: a list longer than the live count is scanned, not returned as stored.
    function testMonitorCycleEnd_CycleEndFiltersEntriesKeptBelowTheThreshold() public {
        _fundAlice(5);
        _registerUsts(5);                       // 0..4
        _cancelOne(2);                          // 1 of 5 removed: below a quarter
        _nextBlockWithPrologue();
        assertEq(readOrderedTaskIds(diamondAddr).length, 5, "kept by the per-block compaction");

        endCycleAsVmSigner(diamondAddr);

        LibCommon.CycleDetails memory details = ICoreViewFacet(diamondAddr).getCycleStateDetails();
        assertEqUint64Array(details.expectedTasksToBeProcessed, uint64Array(0, 1, 3, 4), "expected tasks");
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(0, 1, 3, 4), "list at the cycle end");
    }

    // ────────────────────────────────────────────────────────────────────────
    // States other than a running cycle
    // ────────────────────────────────────────────────────────────────────────

    /// @notice A cycle end with an empty registry starts the next cycle with an empty list, even
    ///         when no block of the ended cycle compacted it.
    function testMonitorCycleEnd_EmptyRegistryCycleEndClearsList() public {
        _fundAlice(2);
        _cancel(_registerUsts(2));
        assertEq(readOrderedTaskIds(diamondAddr).length, 2, "removed tasks still listed before the cycle end");

        uint64 endedIndex = endCycleAsVmSigner(diamondAddr);

        (uint64 index, , , LibCommon.CycleState state) = ICoreViewFacet(diamondAddr).getCycleInfo();
        assertEq(index, endedIndex + 1, "new cycle index");
        assertEq(uint8(state), uint8(LibCommon.CycleState.STARTED), "new cycle state");
        assertEq(readOrderedTaskIds(diamondAddr).length, 0, "list of the new cycle");
    }

    /// @notice Disabling automation with an empty registry moves to READY with an empty list.
    function testDisableAutomation_EmptyRegistryClearsList() public {
        _fundAlice(2);
        _cancel(_registerUsts(2));

        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();

        (, , , LibCommon.CycleState state) = ICoreViewFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.READY), "state after disabling");
        assertEq(readOrderedTaskIds(diamondAddr).length, 0, "list after disabling");
    }

    /// @notice While a transition runs, monitorCycleEnd leaves the list alone: the transition
    ///         replaces it with the survivors when it finalizes.
    function testMonitorCycleEnd_LeavesListDuringTransition() public {
        _fundAlice(2);
        // Task 0 expires shortly after the cycle end, task 1 a day later.
        (, uint64 start, uint64 duration, ) = ICoreViewFacet(diamondAddr).getCycleInfo();
        _registerUst(duration + 100);
        _registerUst(TASK_DURATION);

        uint64 endedIndex = endCycleAsVmSigner(diamondAddr);

        // Process task 0 alone after its expiry: the transition removes it, leaving a removed
        // entry in a two-entry list, half of it.
        vm.warp(start + duration + 100);
        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(endedIndex + 1, singleTask(0));
        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0), "task 0 dropped as expired");

        ICoreFacet(diamondAddr).monitorCycleEnd();
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(0, 1), "list during the transition");

        ICoreFacet(diamondAddr).processTasks(endedIndex + 1, singleTask(1));
        vm.stopPrank();

        (, , , LibCommon.CycleState state) = ICoreViewFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.STARTED), "state after the transition");
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), singleTask(1), "list of the new cycle");
    }

    // ────────────────────────────────────────────────────────────────────────
    // Churn over many blocks
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Registering and cancelling tasks in every block of a cycle keeps the list within
    ///         what the prologue left plus one block's registrations, and the cycle-end scan
    ///         expects only the live tasks. Each block runs as on the chain: the prologue first,
    ///         then the removal of the tasks registered in the previous block, then new
    ///         registrations, which is the sequence the one-block growth bound is about.
    function testMonitorCycleEnd_ChurnInEveryBlockKeepsListBounded() public {
        uint256 baseTasks = 5;
        uint256 perBlock = 10;
        uint256 blocks = 30;
        _fundAlice(baseTasks + perBlock * blocks);
        _registerUsts(baseTasks);
        uint64[] memory previous = new uint64[](0);

        for (uint256 b; b < blocks; b++) {
            _nextBlockWithPrologue();
            _assertListMatchesRegistry("after the prologue");
            uint256 afterPrologue = readOrderedTaskIds(diamondAddr).length;

            if (previous.length > 0) { _cancelNow(previous); }
            previous = _registerUsts(perBlock);

            // Removals add no entry; only this block's registrations do.
            assertEq(readOrderedTaskIds(diamondAddr).length, afterPrologue + perBlock, "one block's growth");
        }

        _cancel(previous);
        endCycleAsVmSigner(diamondAddr);
        LibCommon.CycleDetails memory details = ICoreViewFacet(diamondAddr).getCycleStateDetails();
        assertEqUint64Array(details.expectedTasksToBeProcessed, uint64Array(0, 1, 2, 3, 4), "expected tasks at the cycle end");
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice For random register/cancel sequences over several blocks, every prologue leaves
    ///         the list ascending, holding exactly the live tasks, and with fewer than a quarter
    ///         removed entries unless it equals the live list. Each block runs the prologue, then
    ///         cancels a random subset of the tasks registered in earlier blocks, then registers.
    function testFuzz_MonitorCycleEnd_ListInvariantHolds(uint256 _seed) public {
        uint256 blocks = 8;
        uint256 maxRegistrationsPerBlock = 6;
        _fundAlice(blocks * maxRegistrationsPerBlock);

        for (uint256 b; b < blocks; b++) {
            _nextBlockWithPrologue();
            _assertListMatchesRegistry(string.concat("block ", vm.toString(b)));

            uint256 r = uint256(keccak256(abi.encode(_seed, b)));

            // Every live task was registered in an earlier block, since this block has not
            // registered yet. Cancel each with probability 1/3, chosen from further bits of `r`.
            uint256[] memory live = IRegistryViewFacet(diamondAddr).getTaskIdList();
            uint64[] memory buffer = new uint64[](live.length);
            uint256 n;
            for (uint256 i; i < live.length; i++) {
                if (uint256(keccak256(abi.encode(r, i))) % 3 == 0) {
                    // Task IDs come from a uint64 counter.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    buffer[n++] = uint64(live[i]);
                }
            }
            if (n > 0) {
                uint64[] memory toCancel = new uint64[](n);
                for (uint256 i; i < n; i++) { toCancel[i] = buffer[i]; }
                _cancelNow(toCancel);
            }

            _registerUsts(r % (maxRegistrationsPerBlock + 1));
        }

        _nextBlockWithPrologue();
        _assertListMatchesRegistry("final block");
    }

    // ────────────────────────────────────────────────────────────────────────
    // Growth of one block
    // ────────────────────────────────────────────────────────────────────────

    /// @notice One block adds at most the capacity to the list. The block runs its prologue,
    ///         removes every task of earlier blocks, freeing every slot, and registers up to the
    ///         capacity. A further registration finds no slot, because the tasks it has just
    ///         registered cannot be removed in that block. The next prologue then compacts the
    ///         list back to the live tasks.
    function testOneBlockAddsAtMostTheCapacity() public {
        uint256 capacity = defaultParams.taskCapacity;
        _fundAlice(2 * capacity);

        uint64[] memory earlier = _registerUsts(capacity);
        _nextBlockWithPrologue();
        assertEq(readOrderedTaskIds(diamondAddr).length, capacity, "full registry at the start of the block");

        _cancelNow(earlier);                    // every slot free again
        uint64[] memory current = _registerUsts(capacity);
        assertEq(readOrderedTaskIds(diamondAddr).length, 2 * capacity, "the block added the capacity");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRegistryFacet.TaskRemovalInRegistrationBlock.selector, current[0]));
        IRegistryFacet(diamondAddr).cancelTasks(singleTask(current[0]));

        bytes[] memory auxData;
        vm.prank(alice);
        vm.expectRevert(IRegistryFacet.TaskCapacityReached.selector);
        IRegistryFacet(diamondAddr).register(
            createPayload(0, address(wsupra), abi.encodeCall(wsupra.withdraw, 100)),
            createPredicate(diamondAddr),
            uint64(block.timestamp + TASK_DURATION),
            uint128(100_000), uint128(4 gwei), uint128(60.1 ether), 2, auxData
        );
        assertEq(readOrderedTaskIds(diamondAddr).length, 2 * capacity, "no entry beyond the capacity");

        _nextBlockWithPrologue();
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), current, "compacted to this block's tasks");
    }

    // ────────────────────────────────────────────────────────────────────────
    // Registration once the cycle's end time is reached
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Registers one task as alice with the default parameters, expecting the revert
    ///      `_revertData`.
    function _expectRegisterRevert(bytes memory _revertData) internal {
        bytes[] memory auxData;
        vm.prank(alice);
        vm.expectRevert(_revertData);
        IRegistryFacet(diamondAddr).register(
            createPayload(0, address(wsupra), abi.encodeCall(wsupra.withdraw, 100)),
            createPredicate(diamondAddr),
            uint64(block.timestamp + TASK_DURATION),
            uint128(100_000), uint128(4 gwei), uint128(60.1 ether), 2, auxData
        );
    }

    /// @notice Registration is accepted up to the second before the cycle's end time and refused
    ///         from the end time on, while the cycle is still STARTED because no monitorCycleEnd
    ///         has processed the end yet.
    function testRegister_RefusedFromTheCycleEndTime() public {
        _fundAlice(2);
        (, uint64 start, uint64 duration, ) = ICoreViewFacet(diamondAddr).getCycleInfo();

        vm.warp(start + duration - 1);
        _registerUst(TASK_DURATION);

        vm.warp(start + duration);
        (, , , LibCommon.CycleState state) = ICoreViewFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.STARTED), "end not processed yet");
        _expectRegisterRevert(abi.encodeWithSelector(IRegistryFacet.CycleEndReached.selector));
    }

    /// @notice When the prologue's call fails at the cycle end (modelled by blocks with no
    ///         monitorCycleEnd), the list does not grow in the following blocks: registration is
    ///         refused, and removals add no entry. The first call that succeeds processes the end
    ///         and expects only the live tasks.
    function testMonitorCycleEnd_ListDoesNotGrowAfterTheEndTimeUntilTheEndIsProcessed() public {
        _fundAlice(6);
        _registerUsts(4);                       // 0..3
        _nextBlockWithPrologue();
        (, uint64 start, uint64 duration, ) = ICoreViewFacet(diamondAddr).getCycleInfo();

        vm.warp(start + duration);
        uint256 lengthAtTheEnd = readOrderedTaskIds(diamondAddr).length;
        for (uint256 b; b < 5; b++) {
            nextBlock();                        // no prologue: its call failed
            _expectRegisterRevert(abi.encodeWithSelector(IRegistryFacet.CycleEndReached.selector));
            if (b == 0) { _cancelNow(singleTask(1)); }
            assertEq(readOrderedTaskIds(diamondAddr).length, lengthAtTheEnd, "list after the end time");
        }

        _monitor();                             // the first call that succeeds
        LibCommon.CycleDetails memory details = ICoreViewFacet(diamondAddr).getCycleStateDetails();
        assertEq(uint8(details.state), uint8(LibCommon.CycleState.FINISHED), "end processed");
        assertEqUint64Array(details.expectedTasksToBeProcessed, uint64Array(0, 2, 3), "expected tasks");
    }

    /// @notice A task-owner contract cannot register and cancel a task in one transaction.
    function testAContractCannotRegisterAndCancelInOneTransaction() public {
        uint256 funding = 62 ether;
        vm.deal(address(this), funding);
        RegisterAndCancel owner = new RegisterAndCancel{value: funding}(diamondAddr, address(wsupra));

        LibCommon.AccessListEntry[] memory noAccessList;
        bytes memory payload = abi.encode(uint128(0), address(wsupra), abi.encodePacked(wsupra.withdraw.selector), noAccessList);

        vm.expectRevert(abi.encodeWithSelector(IRegistryFacet.TaskRemovalInRegistrationBlock.selector, uint64(0)));
        owner.registerAndCancel(payload, createPredicate(diamondAddr), uint64(block.timestamp + TASK_DURATION));
        assertEq(readOrderedTaskIds(diamondAddr).length, 0, "nothing registered");
    }
}

/// @dev Test-only task owner that registers a task and cancels it in the same call. It declares
///      IAutomationTaskOwner, as the registry requires of a contract owner (#4469), and holds its
///      own WSUPRA for fees.
contract RegisterAndCancel {
    bytes4 private constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 private constant AUTOMATION_TASK_OWNER_INTERFACE_ID = bytes4(keccak256("IAutomationTaskOwner"));

    IRegistryFacet private immutable registry;

    constructor(address _registry, address _wsupra) payable {
        registry = IRegistryFacet(_registry);
        WrappedSupra(payable(_wsupra)).deposit{value: msg.value}();
        require(WrappedSupra(payable(_wsupra)).approve(_registry, type(uint256).max), "approve failed");
    }

    /// @notice ERC-165.
    function supportsInterface(bytes4 _interfaceId) external pure returns (bool) {
        return _interfaceId == ERC165_INTERFACE_ID || _interfaceId == AUTOMATION_TASK_OWNER_INTERFACE_ID;
    }

    /// @notice Registers one task and cancels it; the task receives ID 0 on a fresh registry.
    function registerAndCancel(bytes memory _payload, bytes memory _predicate, uint64 _expiry) external {
        bytes[] memory auxData;
        registry.register(_payload, _predicate, _expiry, uint128(100_000), uint128(4 gwei), uint128(60.1 ether), 2, auxData);
        uint64[] memory first = new uint64[](1);
        registry.cancelTasks(first);
    }
}
