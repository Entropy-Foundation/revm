// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {EvmGasConfigMock} from "./EvmGasConfigMock.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibDiamond} from "../src/libraries/LibDiamond.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";

/// @dev Exposes LibCommon's internal record sizing helpers as external calls, so that a revert
///      inside them can be caught with vm.expectRevert and the formula can be fuzzed directly.
contract RecordSizingHarness {
    function recordMaxTaskCount(
        uint64 _recordGasLimit,
        uint256 _taskGas,
        uint64 _recordFinalizationGasPerTask,
        uint256 _capacity,
        uint8 _recordTaskSupportPercentage
    ) external pure returns (uint64) {
        return LibCommon.recordMaxTaskCount(
            _recordGasLimit, _taskGas, _recordFinalizationGasPerTask, _capacity, _recordTaskSupportPercentage
        );
    }
}

/// @title Sizing of `processTasks` bookkeeping records (Entropy-Foundation/smr-moonshot#4755).
/// @notice Covers `ConfigFacet.updateRecordGasParameters` / `getRecordGasParameters`, the
/// pre-checks `updateConfigBuffer` and `updateDataLengthCaps` gained,
/// `CoreFacet.getRecordMaxTaskCount` and the `LibCommon` formula behind it. Whether the derived
/// size actually fits a record's gas limit is measured in CycleTransitionGas.t.sol.
///
/// Figures used throughout, from the fixture's defaults:
/// - capacity 160 + 40 = 200;
/// - data-length caps 4,096 / 2,048 / 0 / 0, so a task stores at most 128 + 64 = 192 words;
/// - record gas figures 60,000 per task, 2,500 per stored word, 8,500 finalization per task;
/// - task-support percentage 80, so a record at the production cap budgets 13,421,772 gas.
/// A task therefore costs 60,000 + 2,500 * 192 = 540,000 gas, and the finalizing record's
/// reserve is 200 * 8,500 = 1,700,000 gas.
contract RecordSizingTest is BaseDiamondTest {
    uint64 constant PRODUCTION_CAP = EvmGasConfigMock.DEFAULT_TX_GAS_LIMIT_CAP;

    RecordSizingHarness harness;

    function _deployHarness() internal {
        harness = new RecordSizingHarness();
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

    /// @dev Ends the current, task-free cycle, which applies a buffered config at once
    ///      (LibCore.onCycleEndInternal, no-task branch).
    function _endEmptyCycle() internal {
        (, uint64 startTime, uint64 durationSecs,) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startTime + durationSecs);
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: getRecordMaxTaskCount ::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev At the production cap: (16,777,216 * 80 / 100 - 1,700,000) / 540,000 = 21.
    function testRecordMaxTaskCountAtProductionCap() public view {
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(PRODUCTION_CAP), 21);
    }

    /// @dev At 4,000,000: (3,200,000 - 1,700,000) / 540,000 = 2.
    function testRecordMaxTaskCountAtLowCap() public view {
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(4_000_000), 2);
    }

    /// @dev The reserve alone fills the budget at 2,125,000 (80% of it is 1,700,000). The first
    ///      cap carrying a task is 2,800,000, whose budget of 2,240,000 holds the reserve and one
    ///      540,000-gas task.
    function testRecordMaxTaskCountIsZeroWhenNoTaskFits() public view {
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(0), 0);
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(2_125_000), 0);
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(2_799_999), 0);
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(2_800_000), 1);
    }

    /// @dev The view does not depend on the cap the precompile serves, only on its argument.
    function testRecordMaxTaskCountIgnoresPrecompileCap() public {
        EvmGasConfigMock.mockTxGasLimitCap(vm, 4_000_000);
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(PRODUCTION_CAP), 21);
    }

    /// @dev The count follows the owner-set figures as soon as they change.
    function testRecordMaxTaskCountFollowsRecordGasParameters() public {
        vm.prank(admin);
        IConfigFacet(diamondAddr).updateRecordGasParameters(50_000, 2_000, 10_000, 80);
        // Task 50,000 + 2,000 * 192 = 434,000; reserve 2,000,000;
        // (13,421,772 - 2,000,000) / 434,000 = 26.
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(PRODUCTION_CAP), 26);
    }

    /// @dev The count follows the task-support percentage as soon as it changes. At 100% the
    ///      budget is the whole cap: (16,777,216 - 1,700,000) / 540,000 = 27; at 50%,
    ///      (8,388,608 - 1,700,000) / 540,000 = 12.
    function testRecordMaxTaskCountFollowsSupportPercentage() public {
        vm.prank(admin);
        IConfigFacet(diamondAddr).updateRecordGasParameters(60_000, 2_500, 8_500, 100);
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(PRODUCTION_CAP), 27);

        vm.prank(admin);
        IConfigFacet(diamondAddr).updateRecordGasParameters(60_000, 2_500, 8_500, 50);
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(PRODUCTION_CAP), 12);
    }

    /// @dev The count follows the data-length caps as soon as they change.
    function testRecordMaxTaskCountFollowsDataLengthCaps() public {
        vm.prank(admin);
        IConfigFacet(diamondAddr).updateDataLengthCaps(1024, 512, 0, 0);
        // 32 + 16 = 48 words: task 60,000 + 2,500 * 48 = 180,000;
        // (13,421,772 - 1,700,000) / 180,000 = 65.
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(PRODUCTION_CAP), 65);

        vm.prank(admin);
        IConfigFacet(diamondAddr).updateDataLengthCaps(1024, 512, 100, 3);
        // auxData adds ceil(100 / 32) = 4 words plus 2 per entry: 48 + 4 + 6 = 58 words,
        // task 205,000; 11,721,772 / 205,000 = 57.
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(PRODUCTION_CAP), 57);
    }

    /// @dev A buffered capacity leaves the count unchanged until it applies at the cycle
    ///      boundary, and then the reserve grows with it.
    function testRecordMaxTaskCountFollowsCapacityAtCycleBoundary() public {
        _bufferCapacity(500, 500);
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(PRODUCTION_CAP), 21);

        _endEmptyCycle();

        // (13,421,772 - 1,000 * 8,500) / 540,000 = 9.
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(PRODUCTION_CAP), 9);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::: updateRecordGasParameters ::::::::::::::::::::::::::::::::::::::::::::::::::

    function testUpdateRecordGasParametersStoresAndEmits() public {
        vm.expectEmit(diamondAddr);
        emit IConfigFacet.RecordGasParametersUpdated(70_000, 3_000, 8_000, 90);

        vm.prank(admin);
        IConfigFacet(diamondAddr).updateRecordGasParameters(70_000, 3_000, 8_000, 90);

        (uint64 perTask, uint64 perStoredWord, uint64 finalizationPerTask, uint8 supportPercentage) =
            IConfigFacet(diamondAddr).getRecordGasParameters();
        assertEq(perTask, 70_000);
        assertEq(perStoredWord, 3_000);
        assertEq(finalizationPerTask, 8_000);
        assertEq(supportPercentage, 90);
    }

    function testUpdateRecordGasParametersRevertsIfNotOwner() public {
        vm.expectRevert(LibDiamond.MustBeContractOwner.selector);
        vm.prank(alice);
        IConfigFacet(diamondAddr).updateRecordGasParameters(70_000, 3_000, 8_000, 80);
    }

    function testUpdateRecordGasParametersRevertsOnAnyZeroFigure() public {
        vm.startPrank(admin);
        vm.expectRevert(LibCommon.InvalidRecordGasParameters.selector);
        IConfigFacet(diamondAddr).updateRecordGasParameters(0, 3_000, 8_000, 80);
        vm.expectRevert(LibCommon.InvalidRecordGasParameters.selector);
        IConfigFacet(diamondAddr).updateRecordGasParameters(70_000, 0, 8_000, 80);
        vm.expectRevert(LibCommon.InvalidRecordGasParameters.selector);
        IConfigFacet(diamondAddr).updateRecordGasParameters(70_000, 3_000, 0, 80);
        vm.stopPrank();
    }

    /// @dev The task-support percentage is a share of the gas limit: 0 would size every record
    ///      to no task, and above 100 would budget more gas than the record has.
    function testUpdateRecordGasParametersRevertsOnSupportPercentageOutOfRange() public {
        vm.startPrank(admin);
        vm.expectRevert(LibCommon.InvalidRecordGasParameters.selector);
        IConfigFacet(diamondAddr).updateRecordGasParameters(70_000, 3_000, 8_000, 0);
        vm.expectRevert(LibCommon.InvalidRecordGasParameters.selector);
        IConfigFacet(diamondAddr).updateRecordGasParameters(70_000, 3_000, 8_000, 101);
        // The upper end of the range is accepted.
        IConfigFacet(diamondAddr).updateRecordGasParameters(70_000, 3_000, 8_000, 100);
        vm.stopPrank();
    }

    /// @dev A lower percentage shrinks the budget, and is refused once no task fits at the
    ///      current cap. At the production cap, 13% budgets 2,181,038 gas: the 1,700,000 reserve
    ///      and one 540,000-gas task need 2,240,000, so it is refused; 14% budgets 2,348,810.
    function testUpdateRecordGasParametersRevertsIfSupportPercentageLeavesNoTask() public {
        vm.expectRevert(LibCommon.RecordBudgetTooSmall.selector);
        vm.prank(admin);
        IConfigFacet(diamondAddr).updateRecordGasParameters(60_000, 2_500, 8_500, 13);

        vm.prank(admin);
        IConfigFacet(diamondAddr).updateRecordGasParameters(60_000, 2_500, 8_500, 14);
        assertEq(ICoreFacet(diamondAddr).getRecordMaxTaskCount(PRODUCTION_CAP), 1);
    }

    /// @dev At a 4,000,000 cap the budget is 3,200,000. A reserve of 200 * 13,500 = 2,700,000
    ///      leaves 500,000, below one 540,000-gas task; 200 * 13,000 = 2,600,000 leaves 600,000.
    function testUpdateRecordGasParametersRevertsIfNoTaskFitsAtCurrentCap() public {
        EvmGasConfigMock.mockTxGasLimitCap(vm, 4_000_000);

        vm.expectRevert(LibCommon.RecordBudgetTooSmall.selector);
        vm.prank(admin);
        IConfigFacet(diamondAddr).updateRecordGasParameters(60_000, 2_500, 13_500, 80);

        vm.prank(admin);
        IConfigFacet(diamondAddr).updateRecordGasParameters(60_000, 2_500, 13_000, 80);
    }

    /// @dev A task figure above the whole budget (13,421,772 at the production cap) leaves no
    ///      room for a task either.
    function testUpdateRecordGasParametersRevertsIfTaskExceedsBudget() public {
        vm.expectRevert(LibCommon.RecordBudgetTooSmall.selector);
        vm.prank(admin);
        IConfigFacet(diamondAddr).updateRecordGasParameters(13_500_000, 1, 1, 80);
    }

    /// @dev With a larger capacity buffered, the setter checks the figures against it as well.
    ///      Buffered capacity 1,000: a reserve of 1,000 * 13,000 = 13,000,000 leaves 421,772 of
    ///      the 13,421,772 budget, below one task, although the active capacity (200) fits;
    ///      1,000 * 12,000 leaves 1,421,772.
    function testUpdateRecordGasParametersChecksBufferedCapacity() public {
        _bufferCapacity(500, 500);

        vm.expectRevert(LibCommon.RecordBudgetTooSmall.selector);
        vm.prank(admin);
        IConfigFacet(diamondAddr).updateRecordGasParameters(60_000, 2_500, 13_000, 80);

        vm.prank(admin);
        IConfigFacet(diamondAddr).updateRecordGasParameters(60_000, 2_500, 12_000, 80);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::: cycle-state guard ::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Calls both record-sizing setters as the owner, each expected to revert with
    ///      `ChangeDuringTransition`.
    function _expectSizingSettersRefused() internal {
        vm.startPrank(admin);
        vm.expectRevert(LibCommon.ChangeDuringTransition.selector);
        IConfigFacet(diamondAddr).updateRecordGasParameters(70_000, 3_000, 9_000, 80);
        vm.expectRevert(LibCommon.ChangeDuringTransition.selector);
        IConfigFacet(diamondAddr).updateDataLengthCaps(1024, 512, 0, 0);
        vm.stopPrank();
    }

    /// @dev Calls both record-sizing setters as the owner, each expected to succeed.
    function _expectSizingSettersAccepted() internal {
        vm.startPrank(admin);
        IConfigFacet(diamondAddr).updateRecordGasParameters(70_000, 3_000, 9_000, 80);
        IConfigFacet(diamondAddr).updateDataLengthCaps(1024, 512, 0, 0);
        vm.stopPrank();
    }

    /// @dev Ends the current cycle with one registered task, so the registry is FINISHED with a
    ///      transition in progress.
    function _startTransition() internal {
        registerUst(diamondAddr, 2450);
        (, uint64 startTime, uint64 durationSecs,) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(startTime + durationSecs);
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();
    }

    function _assertCycleState(LibCommon.CycleState _state) internal view {
        (,,, LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(uint8(state), uint8(_state));
    }

    /// @dev The figures and data-length caps change the record size with immediate effect, so
    ///      they are refused while a FINISHED -> STARTED transition is being processed.
    function testRecordSizingSettersRefusedWhenFinished() public {
        _startTransition();
        _assertCycleState(LibCommon.CycleState.FINISHED);
        _expectSizingSettersRefused();
    }

    /// @dev And while a suspension is being processed.
    function testRecordSizingSettersRefusedWhenSuspended() public {
        _startTransition();
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();
        _assertCycleState(LibCommon.CycleState.SUSPENDED);
        _expectSizingSettersRefused();
    }

    function testRecordSizingSettersAcceptedWhenStarted() public {
        _assertCycleState(LibCommon.CycleState.STARTED);
        _expectSizingSettersAccepted();
    }

    /// @dev Disabling automation with no tasks moves the registry straight to READY.
    function testRecordSizingSettersAcceptedWhenReady() public {
        vm.prank(admin);
        ICoreFacet(diamondAddr).disableAutomation();
        _assertCycleState(LibCommon.CycleState.READY);
        _expectSizingSettersAccepted();
    }

    /// @dev A buffered capacity is not guarded: it applies when the next transition starts,
    ///      before the node sizes that transition's records.
    function testUpdateConfigBufferAcceptedDuringTransition() public {
        _startTransition();
        _bufferCapacity(240, 40);
        assertEq(IConfigFacet(diamondAddr).getConfigBuffer().taskCapacity, 240);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::: updateConfigBuffer :::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev At a 4,000,000 cap, a capacity of 400 needs a 3,400,000 reserve, above the
    ///      3,200,000 budget; 280 needs 2,380,000 and leaves room for one task.
    function testUpdateConfigBufferRevertsIfNoTaskFitsAtNewCapacity() public {
        EvmGasConfigMock.mockTxGasLimitCap(vm, 4_000_000);

        vm.expectRevert(LibCommon.RecordBudgetTooSmall.selector);
        _bufferCapacity(300, 100);

        _bufferCapacity(240, 40);
        assertEq(IConfigFacet(diamondAddr).getConfigBuffer().taskCapacity, 240);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::: updateDataLengthCaps :::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev At a 4,000,000 cap, 1,500,000 of the budget is left after the reserve. Caps of
    ///      16,384 / 8,192 bytes are 768 words, a 1,980,000-gas task; 8,192 / 4,096 are 384
    ///      words, a 1,020,000-gas task.
    function testUpdateDataLengthCapsRevertsIfNoTaskFits() public {
        EvmGasConfigMock.mockTxGasLimitCap(vm, 4_000_000);

        vm.expectRevert(LibCommon.RecordBudgetTooSmall.selector);
        vm.prank(admin);
        IConfigFacet(diamondAddr).updateDataLengthCaps(16384, 8192, 0, 0);

        vm.prank(admin);
        IConfigFacet(diamondAddr).updateDataLengthCaps(8192, 4096, 0, 0);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: LibCommon formula ::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    function testRecordStoredWords() public pure {
        assertEq(LibCommon.recordStoredWords(4096, 2048, 0, 0), 192);
        assertEq(LibCommon.recordStoredWords(0, 0, 33, 2), 2 + 4);
        assertEq(LibCommon.recordStoredWords(0, 0, 0, 0), 0);
    }

    function testRecordMaxTaskCountRevertsOnZeroTaskGas() public {
        _deployHarness();
        vm.expectRevert(LibCommon.InvalidRecordGasParameters.selector);
        harness.recordMaxTaskCount(PRODUCTION_CAP, 0, 8_500, 200, 80);
    }

    function testRecordMaxTaskCountRevertsOnSupportPercentageOutOfRange() public {
        _deployHarness();
        vm.expectRevert(LibCommon.InvalidRecordGasParameters.selector);
        harness.recordMaxTaskCount(PRODUCTION_CAP, 540_000, 8_500, 200, 0);
        vm.expectRevert(LibCommon.InvalidRecordGasParameters.selector);
        harness.recordMaxTaskCount(PRODUCTION_CAP, 540_000, 8_500, 200, 101);
    }

    /// @dev The count is the largest n with n * taskGas + capacity * finalizationPerTask within
    ///      the task-support percentage of the gas limit, and 0 when not even the reserve fits.
    function testFuzzRecordMaxTaskCountIsLargestFittingCount(
        uint64 _gasLimit,
        uint64 _perTask,
        uint64 _perStoredWord,
        uint64 _finalizationPerTask,
        uint16 _maxPayloadLength,
        uint16 _maxPredicateLength,
        uint16 _taskCapacity,
        uint16 _sysTaskCapacity,
        uint8 _supportPercentage
    ) public {
        _deployHarness();
        _supportPercentage = uint8(bound(_supportPercentage, 1, 100));
        _perTask = uint64(bound(_perTask, 1, type(uint64).max));
        _perStoredWord = uint64(bound(_perStoredWord, 1, type(uint64).max));
        _finalizationPerTask = uint64(bound(_finalizationPerTask, 1, type(uint64).max));
        uint256 taskGas = LibCommon.recordTaskGas(
            _perTask, _perStoredWord, LibCommon.recordStoredWords(_maxPayloadLength, _maxPredicateLength, 0, 0)
        );
        uint256 capacity = uint256(_taskCapacity) + uint256(_sysTaskCapacity);

        uint256 n = harness.recordMaxTaskCount(_gasLimit, taskGas, _finalizationPerTask, capacity, _supportPercentage);

        uint256 budget = uint256(_gasLimit) * uint256(_supportPercentage) / 100;
        uint256 reserve = capacity * uint256(_finalizationPerTask);
        if (budget <= reserve) {
            assertEq(n, 0);
        } else {
            assertLe(n * taskGas + reserve, budget);
            assertGt((n + 1) * taskGas + reserve, budget);
        }
    }
}
