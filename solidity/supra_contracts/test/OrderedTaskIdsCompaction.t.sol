// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
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

    /// @dev Moves to the next block and cancels alice's PENDING tasks `_taskIds` there, which
    ///      removes them from the registry. The block changes first because an owner cannot remove
    ///      a task in the block it was registered in (LibRegistry.requireRegisteredBeforeThisBlock).
    ///      The cancellation (1 s later) stays far within the 1,200 s test cycle.
    function _cancel(uint64[] memory _taskIds) internal {
        nextBlock();
        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelTasks(_taskIds);
    }

    /// @dev Cancels the single task `_id`.
    function _cancelOne(uint64 _id) internal {
        _cancel(singleTask(_id));
    }

    /// @dev Calls monitorCycleEnd as the VM signer, as BlockMeta's prologue does, at the current
    ///      block time (so within the cycle unless the test warped past its end).
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

        _monitor();

        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(0, 1, 2), "list after monitorCycleEnd");
    }

    /// @notice One removed entry out of five (20 %) is below the quarter, so the list is kept.
    function testMonitorCycleEnd_KeepsListBelowAQuarterRemoved() public {
        _fundAlice(5);
        _registerUsts(5);
        _cancelOne(0);

        _monitor();

        // The removed task 0 stays in the list: 4 live out of 5 entries is above three quarters.
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(0, 1, 2, 3, 4), "list after monitorCycleEnd");
        _assertListMatchesRegistry("below a quarter");
    }

    /// @notice Exactly a quarter removed (one of four) compacts the list: the threshold is inclusive.
    function testMonitorCycleEnd_CompactsAtExactlyAQuarterRemoved() public {
        _fundAlice(4);
        _registerUsts(4);
        _cancelOne(1);

        _monitor();

        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(0, 2, 3), "list after monitorCycleEnd");
    }

    /// @notice A removed entry kept below the threshold is dropped once later removals reach it.
    function testMonitorCycleEnd_CompactsOnceLaterRemovalsReachTheThreshold() public {
        _fundAlice(5);
        _registerUsts(5);
        _cancelOne(0);
        _monitor();
        assertEq(readOrderedTaskIds(diamondAddr).length, 5, "kept below the threshold");

        nextBlock();
        _cancelOne(3);
        _monitor();

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

        _monitor();
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(0, 2, 4, 5, 7), "first compaction");

        nextBlock();
        _registerUsts(2);                       // 8, 9
        toCancel[0] = 0; toCancel[1] = 2; toCancel[2] = 4;
        _cancel(toCancel);
        _monitor();

        // 4 live (5, 7, 8, 9) out of 7 entries.
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(5, 7, 8, 9), "second compaction");
        _assertListMatchesRegistry("after two compactions");
    }

    /// @notice With no live task left, the list is cleared.
    function testMonitorCycleEnd_ClearsListWhenNoTaskIsLive() public {
        _fundAlice(2);
        _cancel(_registerUsts(2));

        _monitor();

        assertEq(readOrderedTaskIds(diamondAddr).length, 0, "list after monitorCycleEnd");
    }

    /// @notice The cycle-end scan after a compaction sees only the live tasks, in order.
    function testMonitorCycleEnd_CycleEndAfterCompactionExpectsLiveTasks() public {
        _fundAlice(6);
        _registerUsts(6);                       // 0..5
        uint64[] memory toCancel = new uint64[](3);
        toCancel[0] = 0; toCancel[1] = 2; toCancel[2] = 4;
        _cancel(toCancel);
        _monitor();

        endCycleAsVmSigner(diamondAddr);

        LibCommon.CycleDetails memory details = ICoreFacet(diamondAddr).getCycleStateDetails();
        assertEq(uint8(details.state), uint8(LibCommon.CycleState.FINISHED), "cycle state");
        assertEqUint64Array(details.expectedTasksToBeProcessed, uint64Array(1, 3, 5), "expected tasks");
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), uint64Array(1, 3, 5), "list at the cycle end");
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

        (uint64 index, , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
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

        (, , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.READY), "state after disabling");
        assertEq(readOrderedTaskIds(diamondAddr).length, 0, "list after disabling");
    }

    /// @notice While a transition runs, monitorCycleEnd leaves the list alone: the transition
    ///         replaces it with the survivors when it finalizes.
    function testMonitorCycleEnd_LeavesListDuringTransition() public {
        _fundAlice(2);
        // Task 0 expires shortly after the cycle end, task 1 a day later.
        (, uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
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

        (, , , LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.STARTED), "state after the transition");
        assertEqUint64Array(readOrderedTaskIds(diamondAddr), singleTask(1), "list of the new cycle");
    }

    // ────────────────────────────────────────────────────────────────────────
    // Churn over many blocks
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Registering and cancelling tasks in every block of a cycle keeps the list within
    ///         the live count plus one block's registrations, and the cycle-end scan walks only
    ///         that much.
    function testMonitorCycleEnd_ChurnInEveryBlockKeepsListBounded() public {
        uint256 baseTasks = 5;
        uint256 perBlock = 10;
        uint256 blocks = 30;
        _fundAlice(baseTasks + perBlock * blocks);
        _registerUsts(baseTasks);

        for (uint256 b; b < blocks; b++) {
            nextBlock();
            // The prologue runs first in a block, then the block's own transactions.
            _monitor();
            _assertListMatchesRegistry("after the prologue");
            _cancel(_registerUsts(perBlock));
            // Before the next prologue the list holds at most the previous bound plus this
            // block's registrations.
            assertLe(readOrderedTaskIds(diamondAddr).length, (4 * baseTasks) / 3 + 1 + perBlock, "within one block's growth");
        }

        endCycleAsVmSigner(diamondAddr);
        LibCommon.CycleDetails memory details = ICoreFacet(diamondAddr).getCycleStateDetails();
        assertEqUint64Array(details.expectedTasksToBeProcessed, uint64Array(0, 1, 2, 3, 4), "expected tasks at the cycle end");
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice For random register/cancel sequences over several blocks, every monitorCycleEnd
    ///         leaves the list ascending, holding exactly the live tasks, and with fewer than a
    ///         quarter removed entries unless it equals the live list.
    function testFuzz_MonitorCycleEnd_ListInvariantHolds(uint256 _seed) public {
        uint256 blocks = 8;
        uint256 maxRegistrationsPerBlock = 6;
        _fundAlice(blocks * maxRegistrationsPerBlock);

        for (uint256 b; b < blocks; b++) {
            nextBlock();
            _monitor();
            _assertListMatchesRegistry(string.concat("block ", vm.toString(b)));

            uint256 r = uint256(keccak256(abi.encode(_seed, b)));
            _registerUsts(r % (maxRegistrationsPerBlock + 1));

            // Cancel each live task with probability 1/3, chosen from further bits of `r`.
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
                _cancel(toCancel);
            }
        }

        nextBlock();
        _monitor();
        _assertListMatchesRegistry("final block");
    }

    // ────────────────────────────────────────────────────────────────────────
    // Growth of one block
    // ────────────────────────────────────────────────────────────────────────

    /// @notice One block adds at most the capacity to the list: with every slot freed by removing
    ///         tasks of earlier blocks, the block registers up to the capacity, and a further
    ///         registration finds no slot because the tasks it just registered cannot be removed.
    function testOneBlockAddsAtMostTheCapacity() public {
        uint256 capacity = defaultParams.taskCapacity;
        _fundAlice(2 * capacity);

        uint64[] memory earlier = _registerUsts(capacity);
        _cancel(earlier);                       // next block: every slot free again
        _monitor();
        assertEq(readOrderedTaskIds(diamondAddr).length, 0, "compacted at the start of the block");

        uint64[] memory current = _registerUsts(capacity);
        assertEq(readOrderedTaskIds(diamondAddr).length, capacity, "the block filled the capacity");

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
        assertEq(readOrderedTaskIds(diamondAddr).length, capacity, "no entry beyond the capacity");
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
