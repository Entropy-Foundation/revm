// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {EvmGasConfigMock} from "./EvmGasConfigMock.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {IRegistryViewFacet} from "../src/interfaces/IRegistryViewFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";

/// @notice Removal of a task the EVM gas config of a new epoch no longer admits (#4087).
///
/// A task is admitted while its maxGasAmount is at most the per-transaction gas cap and, for a
/// UST, its gasPriceCap is at least the minimum gas price. Such a task is removed either by the VM
/// signer's removeRegisteredTask record with reason GAS_CONFIG_UPDATE, which refunds the whole
/// remaining current-cycle fee and the whole deposit, or by processTasks at a cycle transition,
/// which refunds the whole deposit and charges nothing for the new cycle.
///
/// Fixture figures: registerUst registers 100,000 gas at a 4 gwei gasPriceCap with a 60.1 ether
/// deposit and a 1 ether flat fee. With two such tasks committed, each is charged 3 ether for a
/// cycle, so a removal at the very start of a cycle has a 3 ether residual fee.
contract GasConfigUpdateRemovalTest is BaseDiamondTest {
    uint128 constant DEPOSIT = 60.1 ether;
    uint128 constant CYCLE_FEE = 3 ether;
    uint128 constant TASK_GAS = 100_000;
    bytes32 constant TX_HASH = keccak256("txHash");

    /// @dev Registers a UST owned by alice with the given gas figures and a long expiry.
    function registerUstWith(uint128 _maxGasAmount, uint128 _gasPriceCap) internal {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100));
        bytes memory predicate = createPredicate(diamondAddr);

        vm.startPrank(alice);
        wsupra.deposit{value: 100 ether}();
        wsupra.approve(diamondAddr, type(uint256).max);
        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 7200),
            _maxGasAmount,
            _gasPriceCap,
            DEPOSIT,
            2,
            auxData
        );
        vm.stopPrank();
    }

    /// @dev Ends the current cycle and processes `_taskIndexes` in one batch, without expecting any
    /// particular survivor set.
    function transition(uint256[] memory _taskIndexes) internal {
        uint64 nextIndex = endCycle();
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(nextIndex, _taskIndexes);
    }

    /// @dev Ends the current cycle and returns the index processTasks takes for the transition.
    function endCycle() internal returns (uint64 nextIndex) {
        (uint64 index, uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();
        nextIndex = index + 1;
    }

    function removeForGasConfigUpdate(uint64 _cycleIndex, uint64 _taskIndex) internal {
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(
            _cycleIndex, _taskIndex, LibCommon.TaskRemovalReason.GAS_CONFIG_UPDATE, ""
        );
    }

    function twoIndexes() internal pure returns (uint256[] memory indexes) {
        indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 1;
    }

    /// @dev Counts the logs emitted by the registry with `_topic0` and, when `_matchTask` is set,
    /// with `_taskIndex` as the first indexed argument.
    function countLogs(Vm.Log[] memory _logs, bytes32 _topic0, bool _matchTask, uint64 _taskIndex)
        internal
        view
        returns (uint256 count)
    {
        for (uint256 i; i < _logs.length; i++) {
            if (_logs[i].emitter != diamondAddr || _logs[i].topics.length == 0 || _logs[i].topics[0] != _topic0) {
                continue;
            }
            if (_matchTask && (_logs[i].topics.length < 2 || _logs[i].topics[1] != bytes32(uint256(_taskIndex)))) {
                continue;
            }
            count++;
        }
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::: removeRegisteredTask(GAS_CONFIG_UPDATE) :::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev An active UST whose maxGasAmount is above a lowered cap is removed with the whole
    /// residual cycle fee and the whole deposit refunded, from the locked balances.
    function testActiveUstAboveTheCapIsRemovedWithAFullRefund() public {
        registerUst(diamondAddr, 2450);
        registerUst(diamondAddr, 2450);
        processCycleTransition(diamondAddr, twoIndexes());
        assertEq(IRegistryViewFacet(diamondAddr).getCycleLockedFees(), 2 * CYCLE_FEE);

        uint64 cap = 50_000;
        EvmGasConfigMock.mockTxGasLimitCap(vm, cap);
        uint256 aliceBefore = wsupra.balanceOf(alice);
        uint256 diamondBefore = wsupra.balanceOf(diamondAddr);

        vm.expectEmit(true, true, true, true, diamondAddr);
        emit ICoreFacet.TaskRemovedByGasConfigUpdate(
            0, alice, LibCommon.TaskType.UST, TASK_GAS, 4 gwei, cap,
            EvmGasConfigMock.DEFAULT_MIN_GAS_PRICE, CYCLE_FEE, DEPOSIT, TX_HASH
        );
        removeForGasConfigUpdate(2, 0);

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
        assertTrue(IRegistryViewFacet(diamondAddr).ifTaskExists(1));
        assertEq(IRegistryViewFacet(diamondAddr).getGasCommittedForNextCycle(), TASK_GAS);
        assertEq(IRegistryViewFacet(diamondAddr).getTotalDepositedAutomationFees(), DEPOSIT);
        assertEq(IRegistryViewFacet(diamondAddr).getCycleLockedFees(), CYCLE_FEE);
        assertEq(wsupra.balanceOf(alice) - aliceBefore, DEPOSIT + CYCLE_FEE);
        assertEq(diamondBefore - wsupra.balanceOf(diamondAddr), DEPOSIT + CYCLE_FEE);
    }

    /// @dev A UST whose gasPriceCap is below a raised minimum gas price is removed on the same
    /// terms as one above the cap.
    function testActiveUstBelowTheMinimumGasPriceIsRemovedWithAFullRefund() public {
        registerUst(diamondAddr, 2450);
        registerUst(diamondAddr, 2450);
        processCycleTransition(diamondAddr, twoIndexes());

        EvmGasConfigMock.mockMinGasPrice(vm, 5 gwei);
        uint256 aliceBefore = wsupra.balanceOf(alice);

        vm.expectEmit(true, true, true, true, diamondAddr);
        emit ICoreFacet.TaskRemovedByGasConfigUpdate(
            1, alice, LibCommon.TaskType.UST, TASK_GAS, 4 gwei,
            EvmGasConfigMock.DEFAULT_TX_GAS_LIMIT_CAP, 5 gwei, CYCLE_FEE, DEPOSIT, TX_HASH
        );
        removeForGasConfigUpdate(2, 1);

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(1));
        assertEq(wsupra.balanceOf(alice) - aliceBefore, DEPOSIT + CYCLE_FEE);
        assertEq(IRegistryViewFacet(diamondAddr).getCycleLockedFees(), CYCLE_FEE);
    }

    /// @dev The two removal reasons apply different refund policies to identical tasks at the
    /// same instant: ERROR refunds half of the residual cycle fee, GAS_CONFIG_UPDATE all of it.
    /// Both refund the whole deposit of an active task and unlock the same locked fee.
    function testErrorAndGasConfigUpdateRemovalsRefundDifferently() public {
        registerUst(diamondAddr, 2450);
        registerUst(diamondAddr, 2450);
        processCycleTransition(diamondAddr, twoIndexes());
        EvmGasConfigMock.mockTxGasLimitCap(vm, 50_000);

        uint256 beforeError = wsupra.balanceOf(alice);
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(2, 0, LibCommon.TaskRemovalReason.ERROR, "Predicate failed");
        uint256 errorRefund = wsupra.balanceOf(alice) - beforeError;
        assertEq(IRegistryViewFacet(diamondAddr).getCycleLockedFees(), CYCLE_FEE);

        uint256 beforeUpdate = wsupra.balanceOf(alice);
        removeForGasConfigUpdate(2, 1);
        uint256 updateRefund = wsupra.balanceOf(alice) - beforeUpdate;
        assertEq(IRegistryViewFacet(diamondAddr).getCycleLockedFees(), 0);

        assertEq(errorRefund, DEPOSIT + CYCLE_FEE / 2);
        assertEq(updateRefund, DEPOSIT + CYCLE_FEE);
    }

    /// @dev Midway through the cycle the refund is the fee for the remaining half of it.
    function testTheRefundedCycleFeeIsTheFeeForTheRemainingTime() public {
        registerUst(diamondAddr, 2450);
        registerUst(diamondAddr, 2450);
        processCycleTransition(diamondAddr, twoIndexes());
        (, uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration / 2);
        EvmGasConfigMock.mockTxGasLimitCap(vm, 50_000);

        uint256 aliceBefore = wsupra.balanceOf(alice);
        removeForGasConfigUpdate(2, 0);

        assertEq(wsupra.balanceOf(alice) - aliceBefore, DEPOSIT + CYCLE_FEE / 2);
        // The whole fee charged for the cycle is unlocked, not only the refunded share.
        assertEq(IRegistryViewFacet(diamondAddr).getCycleLockedFees(), CYCLE_FEE);
    }

    /// @dev A task the current figures admit is left untouched and nothing is emitted, so a record
    /// scheduled under figures that changed again before it executed has no effect.
    function testATaskTheGasConfigAdmitsIsNotRemoved() public {
        registerUst(diamondAddr, 2450);
        registerUst(diamondAddr, 2450);
        processCycleTransition(diamondAddr, twoIndexes());
        uint256 aliceBefore = wsupra.balanceOf(alice);

        vm.recordLogs();
        removeForGasConfigUpdate(2, 0);

        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
        assertEq(wsupra.balanceOf(alice), aliceBefore);
        assertEq(IRegistryViewFacet(diamondAddr).getCycleLockedFees(), 2 * CYCLE_FEE);
    }

    /// @dev A task index that is not registered is a no-op for GAS_CONFIG_UPDATE, while ERROR
    /// requires the task to exist.
    function testAnUnknownTaskIsANoOpForGasConfigUpdateOnly() public {
        registerUst(diamondAddr, 2450);
        processCycleTransition(diamondAddr, singleIndex(0));
        EvmGasConfigMock.mockTxGasLimitCap(vm, 50_000);

        vm.recordLogs();
        removeForGasConfigUpdate(2, 7);
        assertEq(vm.getRecordedLogs().length, 0);

        vm.expectRevert();
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(2, 7, LibCommon.TaskRemovalReason.ERROR, "Predicate failed");
    }

    /// @dev A GST above the cap is removed without any token movement, and its system gas
    /// commitment for the next cycle is released.
    function testGstAboveTheCapIsRemovedWithoutARefund() public {
        registerGst(diamondAddr, 2450);
        registerGst(diamondAddr, 2450);
        processCycleTransition(diamondAddr, twoIndexes());
        EvmGasConfigMock.mockTxGasLimitCap(vm, 50_000);
        uint256 diamondBefore = wsupra.balanceOf(diamondAddr);

        vm.expectEmit(true, true, true, true, diamondAddr);
        emit ICoreFacet.TaskRemovedByGasConfigUpdate(
            0, bob, LibCommon.TaskType.GST, TASK_GAS, 0, 50_000,
            EvmGasConfigMock.DEFAULT_MIN_GAS_PRICE, 0, 0, TX_HASH
        );
        removeForGasConfigUpdate(2, 0);

        assertFalse(IRegistryViewFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(IRegistryViewFacet(diamondAddr).getSystemGasCommittedForNextCycle(), TASK_GAS);
        assertEq(wsupra.balanceOf(diamondAddr), diamondBefore);
    }

    /// @dev A GST runs at a gas price of 0, so a raised minimum gas price does not remove it.
    function testGstIsNotRemovedForTheMinimumGasPrice() public {
        registerGst(diamondAddr, 2450);
        processCycleTransition(diamondAddr, singleIndex(0));
        EvmGasConfigMock.mockMinGasPrice(vm, 5 gwei);

        vm.recordLogs();
        removeForGasConfigUpdate(2, 0);

        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(IRegistryViewFacet(diamondAddr).ifSysTaskExists(0));
    }

    /// @dev A PENDING UST has paid no cycle fee yet, so it is refunded its whole deposit, where
    /// ERROR refunds half of it.
    function testPendingUstIsRefundedItsWholeDeposit() public {
        registerUst(diamondAddr, 2450);
        registerUst(diamondAddr, 2450);
        EvmGasConfigMock.mockTxGasLimitCap(vm, 50_000);

        uint256 beforeError = wsupra.balanceOf(alice);
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).removeRegisteredTask(1, 0, LibCommon.TaskRemovalReason.ERROR, "Predicate failed");
        assertEq(wsupra.balanceOf(alice) - beforeError, DEPOSIT / 2);

        uint256 beforeUpdate = wsupra.balanceOf(alice);
        removeForGasConfigUpdate(1, 1);
        assertEq(wsupra.balanceOf(alice) - beforeUpdate, DEPOSIT);

        assertEq(IRegistryViewFacet(diamondAddr).totalTasks(), 0);
        assertEq(IRegistryViewFacet(diamondAddr).getGasCommittedForNextCycle(), 0);
        assertEq(IRegistryViewFacet(diamondAddr).getTotalDepositedAutomationFees(), 0);
        assertEq(IRegistryViewFacet(diamondAddr).getCycleLockedFees(), 0);
    }

    /// @dev A CANCELLED UST has paid this cycle's fee and still holds its deposit, so it is
    /// refunded both in full; its next-cycle commitment was already released by the cancellation.
    function testCancelledUstIsRefundedTheResidualFeeAndTheDeposit() public {
        registerUst(diamondAddr, 2450);
        registerUst(diamondAddr, 2450);
        processCycleTransition(diamondAddr, twoIndexes());

        uint64[] memory cancel = new uint64[](1);
        cancel[0] = 0;
        vm.prank(alice);
        IRegistryFacet(diamondAddr).cancelTasks(cancel);
        assertEq(IRegistryViewFacet(diamondAddr).getGasCommittedForNextCycle(), TASK_GAS);

        EvmGasConfigMock.mockTxGasLimitCap(vm, 50_000);
        uint256 aliceBefore = wsupra.balanceOf(alice);
        removeForGasConfigUpdate(2, 0);

        assertEq(wsupra.balanceOf(alice) - aliceBefore, DEPOSIT + CYCLE_FEE);
        assertEq(IRegistryViewFacet(diamondAddr).getGasCommittedForNextCycle(), TASK_GAS);
    }

    /// @dev The caller and cycle-state guards of removeRegisteredTask apply to GAS_CONFIG_UPDATE.
    function testGasConfigUpdateKeepsTheCallerAndStateGuards() public {
        registerUst(diamondAddr, 2450);
        EvmGasConfigMock.mockTxGasLimitCap(vm, 50_000);

        vm.expectRevert(LibUtils.CallerNotVmSigner.selector);
        vm.prank(alice);
        ICoreFacet(diamondAddr).removeRegisteredTask(1, 0, LibCommon.TaskRemovalReason.GAS_CONFIG_UPDATE, "");

        vm.expectRevert(ICoreFacet.InvalidInputCycleIndex.selector);
        removeForGasConfigUpdate(2, 0);

        (uint64 index, uint64 start, uint64 duration, ) = ICoreFacet(diamondAddr).getCycleInfo();
        vm.warp(start + duration);
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).monitorCycleEnd();

        vm.expectRevert(ICoreFacet.InvalidOperationForCurrentCycleState.selector);
        removeForGasConfigUpdate(index, 0);
        assertTrue(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: processTasks ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev A PENDING UST the gas config no longer admits is dropped at the cycle transition with
    /// its whole deposit refunded and is not charged for the new cycle; an admitted task survives.
    function testPendingUstOutsideTheGasConfigIsDroppedAtTheTransition() public {
        registerUstWith(TASK_GAS, 4 gwei);
        registerUstWith(TASK_GAS, 10 gwei);
        EvmGasConfigMock.mockMinGasPrice(vm, 5 gwei);
        uint256 aliceBefore = wsupra.balanceOf(alice);

        vm.recordLogs();
        transition(twoIndexes());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
        assertTrue(IRegistryViewFacet(diamondAddr).ifTaskExists(1));
        assertEq(countLogs(logs, ICoreFacet.TaskRemovedByGasConfigUpdate.selector, true, 0), 1);
        assertEq(countLogs(logs, ICoreFacet.TaskCycleFeeWithdraw.selector, false, 0), 1);
        assertEq(countLogs(logs, ICoreFacet.RemovedTasks.selector, false, 0), 1);

        uint256[] memory active = IRegistryViewFacet(diamondAddr).getActiveTaskIds();
        assertEq(active.length, 1);
        assertEq(active[0], 1);
        // Task 0's whole deposit comes back; task 1 is charged its fee for the new cycle.
        uint128 task1Fee = uint128(IRegistryViewFacet(diamondAddr).getCycleLockedFees());
        assertGt(task1Fee, 0);
        assertEq(wsupra.balanceOf(alice) + task1Fee - aliceBefore, DEPOSIT);
        assertEq(IRegistryViewFacet(diamondAddr).getTotalDepositedAutomationFees(), DEPOSIT);
    }

    /// @dev The transition drop reports the figures that excluded the task and refunds no cycle fee.
    function testTheTransitionDropEmitsTheGasConfigFigures() public {
        registerUstWith(TASK_GAS, 4 gwei);
        EvmGasConfigMock.mockMinGasPrice(vm, 5 gwei);
        uint64 nextIndex = endCycle();

        vm.expectEmit(true, true, true, true, diamondAddr);
        emit ICoreFacet.TaskRemovedByGasConfigUpdate(
            0, alice, LibCommon.TaskType.UST, TASK_GAS, 4 gwei,
            EvmGasConfigMock.DEFAULT_TX_GAS_LIMIT_CAP, 5 gwei, 0, DEPOSIT, TX_HASH
        );
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(nextIndex, singleIndex(0));
        assertEq(IRegistryViewFacet(diamondAddr).totalTasks(), 0);
    }

    /// @dev A deposit the registry cannot transfer at the transition is reported as 0 in the event,
    /// alongside the error event the failed transfer emits, and the task is still dropped.
    function testTheTransitionDropReportsAnUnpaidDepositAsZero() public {
        registerUstWith(TASK_GAS, 4 gwei);
        EvmGasConfigMock.mockMinGasPrice(vm, 5 gwei);
        uint256 diamondBalance = wsupra.balanceOf(diamondAddr);
        vm.prank(diamondAddr);
        wsupra.transfer(address(0xdead), diamondBalance);
        uint64 nextIndex = endCycle();

        vm.expectEmit(true, true, true, true, diamondAddr);
        emit ICoreFacet.TaskRemovedByGasConfigUpdate(
            0, alice, LibCommon.TaskType.UST, TASK_GAS, 4 gwei,
            EvmGasConfigMock.DEFAULT_TX_GAS_LIMIT_CAP, 5 gwei, 0, 0, TX_HASH
        );
        vm.recordLogs();
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamondAddr).processTasks(nextIndex, singleIndex(0));

        assertEq(
            countLogs(vm.getRecordedLogs(), IRegistryFacet.ErrorInsufficientBalanceToRefund.selector, true, 0), 1
        );
        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
    }

    /// @dev An ACTIVE UST still registered when the cycle ends (its removal record had not
    /// executed) is dropped at the transition with its deposit, and not charged again.
    function testActiveUstOutsideTheGasConfigIsDroppedAtTheNextTransition() public {
        registerUstWith(TASK_GAS, 4 gwei);
        registerUstWith(TASK_GAS, 10 gwei);
        transition(twoIndexes());
        assertEq(IRegistryViewFacet(diamondAddr).getActiveTaskIds().length, 2);

        EvmGasConfigMock.mockMinGasPrice(vm, 5 gwei);
        uint256 aliceBefore = wsupra.balanceOf(alice);

        vm.recordLogs();
        transition(twoIndexes());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
        assertEq(countLogs(logs, ICoreFacet.TaskRemovedByGasConfigUpdate.selector, true, 0), 1);
        uint256 charged = IRegistryViewFacet(diamondAddr).getCycleLockedFees();
        assertEq(wsupra.balanceOf(alice) + charged - aliceBefore, DEPOSIT);
        // The new cycle's committed gas, from which its fee rate was derived, was fixed when the
        // previous cycle ended; the commitment carried into the following cycle counts survivors only.
        assertEq(IRegistryViewFacet(diamondAddr).getGasCommittedForNextCycle(), TASK_GAS);
    }

    /// @dev A GST above the cap is dropped at the transition and commits no system gas.
    function testGstAboveTheCapIsDroppedAtTheTransition() public {
        registerGst(diamondAddr, 2450);
        EvmGasConfigMock.mockTxGasLimitCap(vm, 50_000);

        vm.recordLogs();
        transition(singleIndex(0));

        assertEq(countLogs(vm.getRecordedLogs(), ICoreFacet.TaskRemovedByGasConfigUpdate.selector, true, 0), 1);
        assertFalse(IRegistryViewFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(IRegistryViewFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 0);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ABI ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev The node encodes this selector from its bindings; a change here must be matched there.
    function testRemoveRegisteredTaskSelectorIsPinned() public pure {
        assertEq(
            ICoreFacet.removeRegisteredTask.selector,
            bytes4(keccak256("removeRegisteredTask(uint64,uint64,uint8,string)"))
        );
    }

    function singleIndex(uint256 _index) internal pure returns (uint256[] memory indexes) {
        indexes = new uint256[](1);
        indexes[0] = _index;
    }
}
