// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {EvmGasConfigMock} from "./EvmGasConfigMock.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {IRegistryViewFacet} from "../src/interfaces/IRegistryViewFacet.sol";
import {RecordSizingParameters} from "../src/libraries/LibAppStorage.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibDiamond} from "../src/libraries/LibDiamond.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";

/// @dev Exposes LibCommon's internal record sizing formula as an external call, so that a revert
///      inside it can be caught with vm.expectRevert and the formula can be fuzzed directly.
contract RecordSizingHarness {
    function recordMaxTaskCount(
        uint64 _recordGasLimit,
        uint8 _taskSupportPercentage,
        uint256 _storedWords,
        uint256 _capacity
    ) external pure returns (uint64) {
        return LibCommon.recordMaxTaskCount(_recordGasLimit, _taskSupportPercentage, _storedWords, _capacity);
    }
}

/// @title Sizing of `processTasks` bookkeeping records (Entropy-Foundation/smr-moonshot#4755).
/// @notice Covers `CoreFacet.getRecordMaxTaskCount` and the `LibCommon` formula behind it,
/// `ConfigFacet.updateRecordSizingParameters` with its range checks and capacity ceiling, the
/// record-sizing checks of `updateConfigBuffer` and `updateDataLengthCaps` against the values in
/// force after the next cycle boundary, and the parameters and data-length caps buffered to that
/// boundary with the stored-words bound the caps move, including the transition that drops tasks
/// above lowered caps. Whether a derived size actually fits a record's gas limit is measured in
/// CycleTransitionGas.t.sol.
///
/// Figures used throughout, from the fixture's defaults:
/// - capacity 160 + 40 = 200;
/// - data-length caps 4,096 / 2,048 / 0 / 0, so a task stores at most 128 + 64 = 192 words;
/// - the LibCommon gas figures: 100,000 per task, 5,500 per stored word, 10,000 finalization
///   per task;
/// - record sizing parameters 80 percent, maxCapacity 400.
/// A task therefore costs 100,000 + 5,500 * 192 = 1,156,000 gas, the finalizing record's reserve
/// is 200 * 10,000 = 2,000,000 gas, and a record at the production cap budgets 13,421,772 gas.
contract RecordSizingTest is BaseDiamondTest {
    uint64 constant PRODUCTION_CAP = EvmGasConfigMock.DEFAULT_TX_GAS_LIMIT_CAP;
    /// @dev Deposit of a UST registered by _registerUstWith (its automationFeeCapForCycle).
    uint128 constant UST_DEPOSIT = 60.1 ether;

    RecordSizingHarness harness;

    function _deployHarness() internal {
        harness = new RecordSizingHarness();
    }

    /// @dev Record sizing parameters built field by field.
    function _parameters(uint8 _taskSupportPercentage, uint32 _maxCapacity)
        internal
        pure
        returns (RecordSizingParameters memory)
    {
        return RecordSizingParameters({taskSupportPercentage: _taskSupportPercentage, maxCapacity: _maxCapacity});
    }

    /// @dev The fixture's record sizing parameters.
    function _defaults() internal pure returns (RecordSizingParameters memory) {
        return _parameters(80, 400);
    }

    /// @dev Buffers `_p` as the owner; it applies at the next cycle boundary.
    function _bufferParameters(RecordSizingParameters memory _p) internal {
        vm.prank(admin);
        IConfigFacet(diamondAddr).updateRecordSizingParameters(_p);
    }

    function _assertActiveParameters(uint8 _taskSupportPercentage, uint32 _maxCapacity) internal view {
        RecordSizingParameters memory active = IConfigFacet(diamondAddr).getRecordSizingParameters();
        assertEq(active.taskSupportPercentage, _taskSupportPercentage, "active percentage");
        assertEq(active.maxCapacity, _maxCapacity, "active maxCapacity");
    }

    function _count() internal view returns (uint64) {
        return ICoreFacet(diamondAddr).getRecordMaxTaskCount(PRODUCTION_CAP);
    }

    /// @dev Buffers a config equal to the fixture's defaults except for the two capacities.
    ///      Arguments follow updateConfigBuffer's order; the values are those of
    ///      LibDiamondUtils.defaultInitParams().
    function _bufferCapacity(uint16 _taskCapacity, uint16 _sysTaskCapacity) internal {
        vm.prank(admin);
        IConfigFacet(diamondAddr).updateConfigBuffer(
            3600 * 24 * 7, 20_000_000, 0.5 ether, 1 ether, 50, 0.5 ether, 6, 6,
            _taskCapacity, 1200, 3600 * 24 * 180, 20_000_000, _sysTaskCapacity
        );
    }

    function _bufferCaps(uint16 _payload, uint16 _predicate, uint16 _auxLength, uint16 _auxEntries) internal {
        vm.prank(admin);
        IConfigFacet(diamondAddr).updateDataLengthCaps(_payload, _predicate, _auxLength, _auxEntries);
    }

    /// @dev Registers a UST owned by alice with the given inputs and returns its task index.
    function _registerUstWith(bytes memory _payload, bytes memory _predicate, bytes[] memory _auxData)
        internal
        returns (uint64 taskIndex)
    {
        taskIndex = uint64(IRegistryViewFacet(diamondAddr).getNextTaskIndex());
        vm.deal(alice, 200 ether);
        vm.startPrank(alice);
        wsupra.deposit{value: 100 ether}();
        wsupra.approve(diamondAddr, type(uint256).max);
        IRegistryFacet(diamondAddr).register(
            _payload, _predicate, uint64(block.timestamp + 86400), uint128(100_000), uint128(4 gwei), UST_DEPOSIT, 0, _auxData
        );
        vm.stopPrank();
    }

    /// @dev A UST with the fixture's 640-byte payload and 128-byte predicate.
    function _registerFixtureUst() internal returns (uint64) {
        bytes[] memory noAuxData;
        return _registerUstWith(
            createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100)), createPredicate(diamondAddr), noAuxData
        );
    }

    /// @dev A UST with no auxData whose payload and predicate are exactly the given lengths.
    function _registerUstOfLength(uint256 _payloadLength, uint256 _predicateLength) internal returns (uint64) {
        bytes[] memory noAuxData;
        return _registerUstWith(
            payloadOfExactLength(_payloadLength), predicateOfExactLength(diamondAddr, _predicateLength), noAuxData
        );
    }

    /// @dev Processes the FINISHED -> STARTED transition of cycle `_endedIndex` in one record.
    function _processTransition(uint64 _endedIndex, uint64[] memory _tasks) internal {
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(_endedIndex + 1, _tasks);
    }

    function _assertCycleState(LibCommon.CycleState _state) internal view {
        (,,, LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(_state));
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: getRecordMaxTaskCount ::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev At the production cap: (13,421,772 - 2,000,000) / 1,156,000 = 9.
    function testRecordMaxTaskCountAtProductionCap() public view {
        assertEq(_count(), 9);
    }

    /// @dev At 6,000,000: (4,800,000 - 2,000,000) / 1,156,000 = 2; at 4,000,000:
    ///      (3,200,000 - 2,000,000) / 1,156,000 = 1.
    function testRecordMaxTaskCountAtLowCap() public view {
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(6_000_000), 2);
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(4_000_000), 1);
    }

    /// @dev The reserve alone fills the budget at 2,500,000 (80% of it is 2,000,000). The first
    ///      cap carrying a task is 3,945,000, whose budget of 3,156,000 holds the reserve and one
    ///      1,156,000-gas task.
    function testRecordMaxTaskCountIsZeroWhenNoTaskFits() public view {
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(0), 0);
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(2_500_000), 0);
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(3_944_999), 0);
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(3_945_000), 1);
    }

    /// @dev The view does not depend on the cap the precompile serves, only on its argument.
    function testRecordMaxTaskCountIgnoresPrecompileCap() public {
        EvmGasConfigMock.mockTxGasLimitCap(vm, 4_000_000);
        assertEq(_count(), 9);
    }

    /// @dev A buffered task-support percentage leaves the count unchanged until it applies at the
    ///      cycle boundary. At 50%, (8,388,608 - 2,000,000) / 1,156,000 = 5.
    function testRecordMaxTaskCountFollowsSupportPercentageAtCycleBoundary() public {
        _bufferParameters(_parameters(50, 400));
        assertEq(_count(), 9);

        endCycleAsVmSigner(diamondAddr);

        assertEq(_count(), 5);
    }

    /// @dev Parameters buffered during a transition leave its record size unchanged, so a node
    ///      that restarts mid-transition sizes the records as its peers did: they apply at the
    ///      next cycle boundary, not when the transition in progress finalizes.
    function testParametersBufferedMidTransitionApplyAtTheNextBoundary() public {
        uint64 task = _registerFixtureUst();
        uint64 endedIndex = endCycleAsVmSigner(diamondAddr);
        _assertCycleState(LibCommon.CycleState.FINISHED);

        _bufferParameters(_parameters(50, 400));
        assertEq(_count(), 9);

        uint64[] memory tasks = new uint64[](1);
        tasks[0] = task;
        _processTransition(endedIndex, tasks);
        _assertCycleState(LibCommon.CycleState.STARTED);
        assertEq(_count(), 9, "still pending after the transition");

        endCycleAsVmSigner(diamondAddr);
        assertEq(_count(), 5, "applied at the next boundary");
    }

    /// @dev A buffered capacity leaves the count unchanged until it applies at the cycle
    ///      boundary, and then the reserve grows with it: (13,421,772 - 400 * 10,000) / 1,156,000 = 8.
    function testRecordMaxTaskCountFollowsCapacityAtCycleBoundary() public {
        _bufferCapacity(200, 200);
        assertEq(_count(), 9);

        endCycleAsVmSigner(diamondAddr);

        assertEq(_count(), 8);
    }

    /// @dev Buffered caps leave the count unchanged until they apply at the cycle boundary. With
    ///      no task registered, the bound is the new caps' at once: raised to 256 + 128 = 384 words,
    ///      a 2,212,000-gas task and (13,421,772 - 2,000,000) / 2,212,000 = 5; lowered to
    ///      32 + 16 = 48 words, a 364,000-gas task and 31.
    function testRecordMaxTaskCountFollowsDataLengthCapsAtCycleBoundary() public {
        _bufferCaps(8192, 4096, 0, 0);
        assertEq(_count(), 9);
        endCycleAsVmSigner(diamondAddr);
        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 384);
        assertEq(_count(), 5);

        _bufferCaps(1024, 512, 0, 0);
        endCycleAsVmSigner(diamondAddr);
        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 48);
        assertEq(_count(), 31);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::: data-length caps lowered with tasks registered ::::::::::::::::::::::::::::::::::::::::

    /// @dev A task registered under the previous caps keeps its data after the caps are lowered.
    ///      Records stay sized for the previous caps' bound until the transition that applies the
    ///      lower caps finalizes; that transition drops the task above them, refunding its whole
    ///      deposit, and keeps the task within them. Afterwards the bound is the lower caps'.
    function testLoweredCapsDropTasksAboveThemAndKeepTheBoundUntilFinalized() public {
        uint64 oversized = _registerUstOfLength(4096, 2048);
        uint64 withinCaps = _registerFixtureUst();

        // The fixture's 640-byte payload and 128-byte predicate fit 1,024 / 512 bytes.
        _bufferCaps(1024, 512, 0, 0);
        uint64 endedIndex = endCycleAsVmSigner(diamondAddr);

        // The lower caps are in force for registrations, but the cap-size task is still in the
        // registry, so records are sized for 192 words, not 48.
        uint16 payloadCap = IConfigFacet(diamondAddr).getDataLengthCaps().maxPayloadLength;
        assertEq(payloadCap, 1024);
        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 192);
        assertEq(_count(), 9);

        uint256 aliceBalanceBefore = wsupra.balanceOf(alice);
        uint64[] memory tasks = new uint64[](2);
        tasks[0] = oversized;
        tasks[1] = withinCaps;
        // Topics only: the log data carries the deposit and the registration's tx hash.
        vm.expectEmit(true, true, true, false, diamondAddr);
        emit ICoreFacet.TaskRemovedByDataLengthCaps(oversized, alice, LibCommon.TaskType.UST, UST_DEPOSIT, bytes32(0));
        _processTransition(endedIndex, tasks);

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(oversized), "the task above the caps is dropped");
        assertTrue(IRegistryViewFacet(diamondAddr).ifTaskExists(withinCaps), "the task within the caps survives");
        // The dropped task's whole deposit is refunded; the surviving one pays its cycle fee.
        assertGe(wsupra.balanceOf(alice) + 10 ether, aliceBalanceBefore + UST_DEPOSIT, "deposit refunded");
        _assertCycleState(LibCommon.CycleState.STARTED);

        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 48, "bound follows the caps once finalized");
        assertEq(_count(), 31);
    }

    /// @dev A GST above the lowered caps is dropped like a UST, from the system registry as well,
    ///      with no deposit to refund.
    function testLoweredCapsDropSystemTaskAboveThem() public {
        bytes[] memory noAuxData;
        uint64 gst = uint64(IRegistryViewFacet(diamondAddr).getNextTaskIndex());
        vm.prank(bob);
        IRegistryFacet(diamondAddr).registerSystemTask(
            payloadOfExactLength(4096), predicateOfExactLength(diamondAddr, 2048),
            uint64(block.timestamp + 86400), uint128(100_000), 0, noAuxData
        );

        _bufferCaps(1024, 512, 0, 0);
        uint64 endedIndex = endCycleAsVmSigner(diamondAddr);

        uint64[] memory tasks = new uint64[](1);
        tasks[0] = gst;
        // Topics only: the log data carries the deposit refund, 0 for a GST, and the tx hash.
        vm.expectEmit(true, true, true, false, diamondAddr);
        emit ICoreFacet.TaskRemovedByDataLengthCaps(gst, bob, LibCommon.TaskType.GST, 0, bytes32(0));
        _processTransition(endedIndex, tasks);

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(gst));
        assertFalse(IRegistryViewFacet(diamondAddr).ifSysTaskExists(gst), "removed from the system registry");
        assertEq(IRegistryViewFacet(diamondAddr).totalSystemTasks(), 0);
        _assertCycleState(LibCommon.CycleState.STARTED);
        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 48);
    }

    /// @dev Lower caps applied at a FINISHED boundary that is then suspended before any record
    ///      runs: the suspension removes every task, and when it finalizes the bound becomes the
    ///      lower caps' and the lowered-caps state is cleared, as when a FINISHED transition
    ///      finalizes. The next transition then neither drops nor re-checks a task within the
    ///      caps.
    function testLoweredCapsFinalizedThroughSuspensionResetTheBound() public {
        uint64 oversized = _registerUstOfLength(4096, 2048);
        uint64 withinCaps = _registerFixtureUst();

        _bufferCaps(1024, 512, 0, 0);
        uint64 endedIndex = endCycleAsVmSigner(diamondAddr);
        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 192);

        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();
        _assertCycleState(LibCommon.CycleState.SUSPENDED);
        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 192, "the suspension still holds the cap-size task");

        uint64[] memory tasks = new uint64[](2);
        tasks[0] = oversized;
        tasks[1] = withinCaps;
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(endedIndex, tasks);

        _assertCycleState(LibCommon.CycleState.READY);
        assertEq(IRegistryViewFacet(diamondAddr).totalTasks(), 0);
        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 48, "bound follows the caps once the suspension finalizes");
        assertEq(_count(), 31);

        // A task within the caps survives the next transition.
        vm.prank(admin);
        ICoreFacet(diamondAddr).enableAutomation();
        uint64 next = _registerFixtureUst();
        uint64 nextEnded = endCycleAsVmSigner(diamondAddr);
        tasks = new uint64[](1);
        tasks[0] = next;
        _processTransition(nextEnded, tasks);
        assertTrue(IRegistryViewFacet(diamondAddr).ifTaskExists(next));
        _assertCycleState(LibCommon.CycleState.STARTED);
    }

    /// @dev auxData is checked by entry count and by combined length. Under caps of 100 bytes in
    ///      2 entries, three tasks register: two 10-byte entries, one 100-byte entry, and one
    ///      20-byte entry. Lowered to 60 bytes in 1 entry, the first is above the entry cap, the
    ///      second above the length cap, and only the third survives.
    function testLoweredAuxDataCapsDropTasksAboveEitherCap() public {
        _bufferCaps(4096, 2048, 100, 2);
        endCycleAsVmSigner(diamondAddr);

        bytes memory payload = createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100));
        bytes memory predicate = createPredicate(diamondAddr);
        bytes[] memory twoEntries = new bytes[](2);
        twoEntries[0] = new bytes(10);
        twoEntries[1] = new bytes(10);
        bytes[] memory longEntry = new bytes[](1);
        longEntry[0] = new bytes(100);
        bytes[] memory shortEntry = new bytes[](1);
        shortEntry[0] = new bytes(20);
        uint64[] memory tasks = new uint64[](3);
        tasks[0] = _registerUstWith(payload, predicate, twoEntries);
        tasks[1] = _registerUstWith(payload, predicate, longEntry);
        tasks[2] = _registerUstWith(payload, predicate, shortEntry);

        _bufferCaps(4096, 2048, 60, 1);
        uint64 endedIndex = endCycleAsVmSigner(diamondAddr);
        _processTransition(endedIndex, tasks);

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(tasks[0]), "above the entry cap");
        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(tasks[1]), "above the combined-length cap");
        assertTrue(IRegistryViewFacet(diamondAddr).ifTaskExists(tasks[2]), "within both caps");
    }

    /// @dev Raised caps raise the bound at the cycle boundary, before the transition's records are
    ///      sized, and drop nothing.
    function testRaisedCapsRaiseTheBoundAtTheBoundary() public {
        uint64 task = _registerFixtureUst();
        _bufferCaps(8192, 4096, 0, 0);
        uint64 endedIndex = endCycleAsVmSigner(diamondAddr);

        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 384);
        assertEq(_count(), 5);

        uint64[] memory tasks = new uint64[](1);
        tasks[0] = task;
        _processTransition(endedIndex, tasks);
        assertTrue(IRegistryViewFacet(diamondAddr).ifTaskExists(task));
        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 384);
    }

    /// @dev Caps buffered during a transition leave its record size unchanged: they apply at the
    ///      next cycle boundary, not when the transition in progress finalizes.
    function testCapsBufferedMidTransitionApplyAtTheNextBoundary() public {
        uint64 task = _registerFixtureUst();
        uint64 endedIndex = endCycleAsVmSigner(diamondAddr);
        _assertCycleState(LibCommon.CycleState.FINISHED);

        _bufferCaps(8192, 4096, 0, 0);
        assertEq(_count(), 9);

        uint64[] memory tasks = new uint64[](1);
        tasks[0] = task;
        _processTransition(endedIndex, tasks);
        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 192, "still pending after the transition");

        endCycleAsVmSigner(diamondAddr);
        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 384, "applied at the next boundary");
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::: updateRecordSizingParameters :::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev The parameters are written to the buffer, and the ones in force are unchanged until
    ///      the cycle boundary, which applies and clears the buffer.
    function testUpdateRecordSizingParametersBuffersAndEmits() public {
        RecordSizingParameters memory p = _parameters(75, 300);
        vm.expectEmit(diamondAddr);
        emit IConfigFacet.RecordSizingParametersBufferUpdated(p);

        _bufferParameters(p);

        RecordSizingParameters memory buffered = IConfigFacet(diamondAddr).getRecordSizingParametersBuffer();
        assertEq(buffered.taskSupportPercentage, 75);
        assertEq(buffered.maxCapacity, 300);
        _assertActiveParameters(80, 400);

        endCycleAsVmSigner(diamondAddr);

        _assertActiveParameters(75, 300);
        buffered = IConfigFacet(diamondAddr).getRecordSizingParametersBuffer();
        assertEq(buffered.taskSupportPercentage, 0, "buffer cleared");
        assertEq(buffered.maxCapacity, 0, "buffer cleared");
    }

    /// @dev A second call before the boundary replaces the buffer.
    function testUpdateRecordSizingParametersReplacesTheBuffer() public {
        _bufferParameters(_parameters(60, 300));
        _bufferParameters(_parameters(70, 350));
        endCycleAsVmSigner(diamondAddr);
        _assertActiveParameters(70, 350);
    }

    function testUpdateRecordSizingParametersRevertsIfNotOwner() public {
        vm.expectRevert(LibDiamond.MustBeContractOwner.selector);
        vm.prank(alice);
        IConfigFacet(diamondAddr).updateRecordSizingParameters(_defaults());
    }

    /// @dev The owner can make records smaller, not larger, than the benchmark supports: a
    ///      percentage of 0 or above the maximum and a zero maxCapacity are refused. The maximum
    ///      itself is accepted.
    function testUpdateRecordSizingParametersRevertsOutsideRange() public {
        vm.startPrank(admin);
        vm.expectRevert(LibCommon.InvalidRecordSizingParameters.selector);
        IConfigFacet(diamondAddr).updateRecordSizingParameters(_parameters(81, 400));
        vm.expectRevert(LibCommon.InvalidRecordSizingParameters.selector);
        IConfigFacet(diamondAddr).updateRecordSizingParameters(_parameters(0, 400));
        vm.expectRevert(LibCommon.InvalidRecordSizingParameters.selector);
        IConfigFacet(diamondAddr).updateRecordSizingParameters(_parameters(80, 0));

        IConfigFacet(diamondAddr).updateRecordSizingParameters(_defaults());
        IConfigFacet(diamondAddr).updateRecordSizingParameters(_parameters(50, 400));
        vm.stopPrank();
    }

    /// @dev A lower percentage shrinks the budget, and is refused once no task fits at the
    ///      current cap. At the production cap, 18% budgets 3,019,898 gas: the 2,000,000 reserve
    ///      and one 1,156,000-gas task need 3,156,000; 19% budgets 3,187,671.
    function testUpdateRecordSizingParametersRevertsIfSupportPercentageLeavesNoTask() public {
        vm.expectRevert(LibCommon.RecordBudgetTooSmall.selector);
        _bufferParameters(_parameters(18, 400));

        _bufferParameters(_parameters(19, 400));
        endCycleAsVmSigner(diamondAddr);
        assertEq(_count(), 1);
    }

    /// @dev The percentage is checked against the capacity in force after the boundary. With
    ///      capacity 400 buffered, the reserve is 4,000,000: 30% budgets 5,033,164, below the
    ///      5,156,000 one task needs, although at the active capacity (200) it would fit; 31%
    ///      budgets 5,200,936.
    function testUpdateRecordSizingParametersChecksBufferedCapacity() public {
        _bufferCapacity(300, 100);

        vm.expectRevert(LibCommon.RecordBudgetTooSmall.selector);
        _bufferParameters(_parameters(30, 400));

        _bufferParameters(_parameters(31, 400));
    }

    /// @dev And against the stored-words bound of buffered caps. Caps of 384 words make a task
    ///      2,212,000 gas: 25% budgets 4,194,304, below the 4,212,000 one task and the reserve
    ///      need, although at the current 192 words it would fit; 26% budgets 4,362,076.
    function testUpdateRecordSizingParametersChecksBufferedCaps() public {
        _bufferCaps(8192, 4096, 0, 0);

        vm.expectRevert(LibCommon.RecordBudgetTooSmall.selector);
        _bufferParameters(_parameters(25, 400));

        _bufferParameters(_parameters(26, 400));
    }

    /// @dev maxCapacity may not be below the capacity in force after the boundary: the active
    ///      one when no config is buffered.
    function testUpdateRecordSizingParametersRevertsIfMaxCapacityBelowActiveCapacity() public {
        vm.expectRevert(LibCommon.CapacityAboveRecordGasLimit.selector);
        _bufferParameters(_parameters(80, 199));
        _bufferParameters(_parameters(80, 200));
    }

    /// @dev The buffered one when a config is buffered, whether it is larger than the active one...
    function testUpdateRecordSizingParametersRevertsIfMaxCapacityBelowBufferedCapacity() public {
        _bufferCapacity(300, 50);
        vm.expectRevert(LibCommon.CapacityAboveRecordGasLimit.selector);
        _bufferParameters(_parameters(80, 349));
        _bufferParameters(_parameters(80, 350));
    }

    /// @dev ...or smaller: the buffers apply together, so maxCapacity may be lowered below the
    ///      active capacity in the same boundary that lowers the capacity.
    function testUpdateRecordSizingParametersLowersMaxCapacityWithBufferedCapacity() public {
        _bufferCapacity(100, 50);
        _bufferParameters(_parameters(80, 150));

        endCycleAsVmSigner(diamondAddr);

        _assertActiveParameters(80, 150);
        assertEq(IConfigFacet(diamondAddr).getConfig().taskCapacity, 100);
    }

    /// @dev The parameters are buffered to a cycle boundary like the caps and the capacity, so
    ///      all three are accepted while a transition is processed, FINISHED or SUSPENDED.
    function testBufferedSizingInputsAcceptedDuringTransition() public {
        registerUst(diamondAddr, 2450);
        endCycleAsVmSigner(diamondAddr);
        _assertCycleState(LibCommon.CycleState.FINISHED);
        _bufferCaps(8192, 4096, 0, 0);
        _bufferCapacity(240, 40);
        _bufferParameters(_parameters(70, 400));
        assertEq(IConfigFacet(diamondAddr).getDataLengthCapsBuffer().maxPayloadLength, 8192);
        assertEq(IConfigFacet(diamondAddr).getConfigBuffer().taskCapacity, 240);
        assertEq(IConfigFacet(diamondAddr).getRecordSizingParametersBuffer().taskSupportPercentage, 70);

        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();
        _assertCycleState(LibCommon.CycleState.SUSPENDED);
        _bufferParameters(_parameters(60, 400));
        assertEq(IConfigFacet(diamondAddr).getRecordSizingParametersBuffer().taskSupportPercentage, 60);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::: updateConfigBuffer :::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev A capacity above maxCapacity (400) is refused until the owner buffers a larger
    ///      maxCapacity, declaring the benchmark was re-run at that size; both buffers then apply
    ///      at the same boundary.
    function testUpdateConfigBufferRevertsAboveRecordMaxCapacity() public {
        vm.expectRevert(LibCommon.CapacityAboveRecordGasLimit.selector);
        _bufferCapacity(301, 100);

        _bufferCapacity(300, 100);

        raiseRecordMaxCapacity(diamondAddr, 500);
        _bufferCapacity(301, 100);
        assertEq(IConfigFacet(diamondAddr).getConfigBuffer().taskCapacity, 301);

        endCycleAsVmSigner(diamondAddr);
        _assertActiveParameters(80, 500);
        assertEq(IConfigFacet(diamondAddr).getConfig().taskCapacity, 301);
    }

    /// @dev The capacity is checked against the maxCapacity in force after the boundary, so a
    ///      buffered lower maxCapacity refuses a capacity the active one would accept.
    function testUpdateConfigBufferChecksBufferedMaxCapacity() public {
        _bufferParameters(_parameters(80, 300));

        vm.expectRevert(LibCommon.CapacityAboveRecordGasLimit.selector);
        _bufferCapacity(250, 100);

        _bufferCapacity(200, 100);
    }

    /// @dev At a 4,000,000 cap the budget is 3,200,000. A capacity of 400 needs a 4,000,000
    ///      reserve, above the budget; 205 needs 2,050,000 and leaves 1,150,000, below one
    ///      1,156,000-gas task; 204 needs 2,040,000 and leaves room for one.
    function testUpdateConfigBufferRevertsIfNoTaskFitsAtNewCapacity() public {
        EvmGasConfigMock.mockTxGasLimitCap(vm, 4_000_000);

        vm.expectRevert(LibCommon.RecordBudgetTooSmall.selector);
        _bufferCapacity(300, 100);
        vm.expectRevert(LibCommon.RecordBudgetTooSmall.selector);
        _bufferCapacity(165, 40);

        _bufferCapacity(164, 40);
        assertEq(IConfigFacet(diamondAddr).getConfigBuffer().taskCapacity, 164);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::: updateDataLengthCaps :::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev At a 4,000,000 cap, 1,200,000 of the budget is left after the reserve, room for a task
    ///      of up to 200 words (100,000 + 5,500 * 200). Raising the payload cap to 4,384 bytes
    ///      makes 137 + 64 = 201 words; 4,352 bytes makes 136 + 64 = 200.
    function testUpdateDataLengthCapsRevertsIfNoTaskFits() public {
        EvmGasConfigMock.mockTxGasLimitCap(vm, 4_000_000);

        vm.expectRevert(LibCommon.RecordBudgetTooSmall.selector);
        _bufferCaps(4384, 2048, 0, 0);

        _bufferCaps(4352, 2048, 0, 0);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: LibCommon formula ::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    function testRecordStoredWords() public pure {
        assertEq(LibCommon.recordStoredWords(4096, 2048, 0, 0), 192);
        assertEq(LibCommon.recordStoredWords(0, 0, 33, 2), 2 + 4);
        assertEq(LibCommon.recordStoredWords(0, 0, 0, 0), 0);
        assertEq(LibCommon.newDataLengthCaps(1024, 512, 100, 3).storedWords, 32 + 16 + 4 + 6);
    }

    /// @dev The formula itself refuses an unset percentage (zero) and one above
    ///      MAX_RECORD_TASK_SUPPORT_PERCENTAGE, the range the setter enforces, so a value stored
    ///      by any other path cannot size records larger than the benchmark supports.
    function testRecordMaxTaskCountRevertsOutsidePercentageRange() public {
        _deployHarness();
        vm.expectRevert(LibCommon.InvalidRecordSizingParameters.selector);
        harness.recordMaxTaskCount(PRODUCTION_CAP, 0, 192, 200);
        vm.expectRevert(LibCommon.InvalidRecordSizingParameters.selector);
        harness.recordMaxTaskCount(PRODUCTION_CAP, 81, 192, 200);
        assertEq(harness.recordMaxTaskCount(PRODUCTION_CAP, 80, 192, 200), 9);
        assertEq(harness.recordMaxTaskCount(PRODUCTION_CAP, 1, 192, 0), 0);
    }

    /// @dev The count is the largest n with n * taskGas + capacity * RECORD_FINALIZATION_GAS_PER_TASK
    ///      within the task-support percentage of the gas limit, and 0 when not even the reserve
    ///      fits.
    function testFuzzRecordMaxTaskCountIsLargestFittingCount(
        uint64 _gasLimit,
        uint8 _supportPercentage,
        uint32 _storedWords,
        uint16 _taskCapacity,
        uint16 _sysTaskCapacity
    ) public {
        _deployHarness();
        uint8 percentage = uint8(bound(_supportPercentage, 1, LibCommon.MAX_RECORD_TASK_SUPPORT_PERCENTAGE));
        uint256 words = bound(_storedWords, 0, 137_214);
        uint256 taskGas = LibCommon.recordTaskGas(words);
        uint256 capacity = uint256(_taskCapacity) + uint256(_sysTaskCapacity);

        uint256 n = harness.recordMaxTaskCount(_gasLimit, percentage, words, capacity);

        uint256 budget = uint256(_gasLimit) * uint256(percentage) / 100;
        uint256 reserve = capacity * uint256(LibCommon.RECORD_FINALIZATION_GAS_PER_TASK);
        if (budget <= reserve) {
            assertEq(n, 0);
        } else {
            assertLe(n * taskGas + reserve, budget);
            assertGt((n + 1) * taskGas + reserve, budget);
        }
    }
}
