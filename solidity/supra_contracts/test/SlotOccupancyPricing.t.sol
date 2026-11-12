// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {IRegistryViewFacet} from "../src/interfaces/IRegistryViewFacet.sol";
import {Deployment, InitParams, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";
import {LibAccounting} from "../src/libraries/LibAccounting.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";

/// @notice Tests for pricing user tasks on task occupancy as well as gas occupancy
/// (Entropy-Foundation/smr-moonshot#4921): the congestion fee on the larger of the gas share and
/// the task share, the billed-gas ramp toward a slot's worth of gas above the congestion
/// threshold, the per-cycle task-count snapshots, refunds recomputed from those snapshots, and the
/// next cycle's user and system task capacities bounding registration.
/// @dev The registry under test has CAPACITY = 10 user tasks and a gas cap of 2,500,000, so a
/// slot's worth of gas is FLOOR_GAS = 250,000, with a 50% congestion threshold, exponent 6, base
/// and congestion fees of 0.5 SUPRA per second and 600-second cycles. Tasks declare SMALL_GAS =
/// 50,000, below FLOOR_GAS.
contract SlotOccupancyPricingTest is BaseDiamondTest {
    uint16 constant CAPACITY = 10;
    uint128 constant GAS_CAP = 2_500_000;
    uint128 constant FLOOR_GAS = GAS_CAP / CAPACITY;
    uint64 constant CYCLE = 600;
    uint64 constant TASK_DURATION_CAP = 14 days;
    uint128 constant BASE_FEE = 0.5 ether;
    uint128 constant CONGESTION_FEE = 0.5 ether;
    uint128 constant FLAT_FEE = 0.5 ether;
    uint8 constant THRESHOLD = 50;
    uint8 constant EXPONENT = 6;
    uint128 constant SMALL_GAS = 50_000;
    /// @dev Fee cap per cycle, also the deposit: above every fee these tests charge, so no task
    /// is dropped for exceeding it.
    uint128 constant FEE_CAP = 400 ether;

    /// @dev Fee per second with every slot or the whole gas cap taken: the base fee plus the
    /// congestion fee at 100% usage, 0.5 * ((1 + 0.5)^6 - 1) = 5.1953125 SUPRA, which is exact in
    /// the registry's 1e8 fixed point.
    uint128 constant FULL_RATE = 5.6953125 ether;

    address diamond;
    address owner = address(0xA0);

    function setUpRegistry() internal {
        InitParams memory p = InitParams({
            taskDurationCapSecs: TASK_DURATION_CAP,
            registryMaxGasCap: GAS_CAP,
            automationBaseFeeWeiPerSec: BASE_FEE,
            flatRegistrationFeeWei: FLAT_FEE,
            congestionThresholdPercentage: THRESHOLD,
            congestionBaseFeeWeiPerSec: CONGESTION_FEE,
            congestionExponent: EXPONENT,
            maxCongestionExponent: EXPONENT,
            taskCapacity: CAPACITY,
            cycleDurationSecs: CYCLE,
            sysTaskDurationCapSecs: 180 days,
            sysRegistryMaxGasCap: GAS_CAP,
            sysTaskCapacity: 5,
            registrationEnabled: true,
            automationEnabled: true
        });
        vm.prank(admin);
        Deployment memory d = LibDiamondUtils.deploy(admin, address(wsupra), p);
        diamond = d.diamond;

        vm.deal(owner, 100_000 ether);
        vm.startPrank(owner);
        wsupra.deposit{value: 100_000 ether}();
        wsupra.approve(diamond, type(uint256).max);
        vm.stopPrank();
    }

    function registerSmallTask() internal returns (uint64 taskIndex) {
        taskIndex = IRegistryViewFacet(diamond).getNextTaskIndex();
        bytes[] memory aux;
        vm.prank(owner);
        IRegistryFacet(diamond).register(
            createPayload(0, address(wsupra), abi.encodeCall(wsupra.withdraw, 1)),
            createPredicate(diamond),
            uint64(block.timestamp) + TASK_DURATION_CAP,
            SMALL_GAS,
            uint128(1 gwei),
            FEE_CAP,
            0,
            aux
        );
    }

    /// @dev Registers `_count` small tasks, runs the transition into the next cycle, and returns
    /// their indexes.
    function registerAndActivate(uint256 _count) internal returns (uint64[] memory ids) {
        ids = new uint64[](_count);
        for (uint256 i; i < _count; i++) {
            ids[i] = registerSmallTask();
        }
        processCycleTransition(diamond, ids);
    }

    /// @dev The fee for a whole cycle, the formula of LibAccounting.calculateAutomationFeeForInterval.
    function cycleFee(uint128 _feePerSec, uint128 _billedGas) internal pure returns (uint256) {
        uint256 ratio = (uint256(CYCLE) * _billedGas * 1e8) / GAS_CAP;
        return (uint256(_feePerSec) * ratio) / 1e8;
    }

    function occupancy(uint32 _tasks) internal pure returns (LibAccounting.CycleOccupancy memory) {
        return LibAccounting.CycleOccupancy({
            committedGas: 0,
            committedTasks: _tasks,
            registryMaxGasCap: 12_500_000,
            taskCapacity: 50,
            congestionThresholdPercentage: THRESHOLD,
            congestionExponent: EXPONENT,
            automationBaseFeeWeiPerSec: BASE_FEE,
            congestionBaseFeeWeiPerSec: CONGESTION_FEE
        });
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::: billedGas ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev At or below the threshold a task is billed its own gas.
    function testBilledGasIsOwnGasUpToTheThreshold() public pure {
        assertEq(LibAccounting.billedGas(77_000, occupancy(0)), 77_000);
        assertEq(LibAccounting.billedGas(77_000, occupancy(1)), 77_000);
        assertEq(LibAccounting.billedGas(77_000, occupancy(25)), 77_000, "50% is not above the threshold");
    }

    /// @dev Above the threshold the billed gas rises linearly toward a slot's worth of gas,
    /// cap / capacity = 250,000, reaching it when every slot is taken. The figures are the worked
    /// example in LibAccounting.billedGas.
    function testBilledGasRampsToTheSlotFloor() public pure {
        assertEq(LibAccounting.billedGas(77_000, occupancy(26)), 83_920, "52%: ramp 0.04");
        assertEq(LibAccounting.billedGas(77_000, occupancy(30)), 111_600, "60%: ramp 0.2");
        assertEq(LibAccounting.billedGas(77_000, occupancy(38)), 166_960, "76%: ramp 0.52");
        assertEq(LibAccounting.billedGas(77_000, occupancy(45)), 215_400, "90%: ramp 0.8");
        assertEq(LibAccounting.billedGas(77_000, occupancy(50)), 250_000, "100%: a whole slot");
    }

    /// @dev A task declaring a slot's worth of gas or more is billed its own gas at any occupancy.
    function testBilledGasNeverChangesATaskAtOrAboveTheSlotFloor() public pure {
        assertEq(LibAccounting.billedGas(250_000, occupancy(50)), 250_000);
        assertEq(LibAccounting.billedGas(467_500, occupancy(50)), 467_500);
    }

    /// @dev A 100% threshold disables the ramp, as it disables the congestion fee.
    function testBilledGasRampIsDisabledByAFullThreshold() public pure {
        LibAccounting.CycleOccupancy memory occ = occupancy(50);
        occ.congestionThresholdPercentage = 100;
        assertEq(LibAccounting.billedGas(77_000, occ), 77_000);
    }

    /// @dev A zero congestion base fee disables the ramp, as it disables the congestion fee.
    function testBilledGasRampIsDisabledByAZeroCongestionBaseFee() public pure {
        LibAccounting.CycleOccupancy memory occ = occupancy(50);
        occ.congestionBaseFeeWeiPerSec = 0;
        assertEq(LibAccounting.billedGas(77_000, occ), 77_000);
    }

    /// @dev A task count above the capacity is billed as a full registry.
    function testBilledGasCountsTheTaskShareAsAtMostFull() public pure {
        assertEq(LibAccounting.billedGas(77_000, occupancy(60)), 250_000);
    }

    /// @dev The billed gas is never below the declared gas, never above the larger of the
    /// declared gas and the slot floor, and does not decrease as tasks are added.
    function testFuzzBilledGasIsBoundedAndMonotonic(uint128 _gas, uint32 _tasks) public pure {
        uint128 gas = uint128(bound(_gas, 1, 30_000_000));
        uint32 tasks = uint32(bound(_tasks, 0, 60));
        uint128 billed = LibAccounting.billedGas(gas, occupancy(tasks));
        uint128 upper = gas > 250_000 ? gas : 250_000;
        assertGe(billed, gas);
        assertLe(billed, upper);
        assertGe(LibAccounting.billedGas(gas, occupancy(tasks + 1)), billed);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::: Occupancy measures ::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Shares are percentages scaled by 1e8 and counted as at most 100%.
    function testCongestionPercentagesAreSharesOfTheLimits() public pure {
        LibAccounting.CycleOccupancy memory occ = occupancy(30);
        occ.committedGas = 2_500_000; // 20% of 12,500,000
        assertEq(LibAccounting.congestionPercentageByGas(occ), 20e8);
        assertEq(LibAccounting.congestionPercentageByTasks(occ), 60e8);
        assertEq(LibAccounting.congestionThreshold(occ), 50e8);

        occ.committedGas = 25_000_000;
        occ.committedTasks = 75;
        assertEq(LibAccounting.congestionPercentageByGas(occ), 100e8, "gas share counted as at most 100%");
        assertEq(LibAccounting.congestionPercentageByTasks(occ), 100e8, "task share counted as at most 100%");
    }

    /// @dev The congestion surplus is the larger share's excess over the threshold; the task
    /// surplus is the task share's alone; both are zero at or below the threshold.
    function testCongestionSurplusesAreExcessesOverTheThreshold() public pure {
        LibAccounting.CycleOccupancy memory occ = occupancy(30); // tasks 60%
        occ.committedGas = 10_000_000; // gas 80%
        assertEq(LibAccounting.congestionSurplus(occ), 30e8, "the larger share, gas");
        assertEq(LibAccounting.congestionSurplusByTasks(occ), 10e8, "the task share alone");

        occ.committedGas = 0;
        occ.committedTasks = 25; // 50%, at the threshold
        assertEq(LibAccounting.congestionSurplus(occ), 0);
        assertEq(LibAccounting.congestionSurplusByTasks(occ), 0);
    }

    /// @dev Congestion is priced only with a threshold below 100% and a non-zero congestion base fee.
    function testCongestionIsPricedOnlyWithAThresholdAndABaseFee() public pure {
        LibAccounting.CycleOccupancy memory occ = occupancy(50);
        assertTrue(LibAccounting.isCongestionPriced(occ));
        occ.congestionThresholdPercentage = 100;
        assertFalse(LibAccounting.isCongestionPriced(occ));
        occ.congestionThresholdPercentage = THRESHOLD;
        occ.congestionBaseFeeWeiPerSec = 0;
        assertFalse(LibAccounting.isCongestionPriced(occ));
    }

    /// @dev A zero task capacity has no task share, so it bills a task its own gas.
    function testBilledGasWithAZeroCapacityIsOwnGas() public pure {
        LibAccounting.CycleOccupancy memory occ = occupancy(50);
        occ.taskCapacity = 0;
        assertEq(LibAccounting.billedGas(77_000, occ), 77_000);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::: Congestion rate ::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev The task share is priced as the gas share is: a cycle with every slot taken and no
    /// gas has the rate of a cycle with the whole gas cap taken and no tasks.
    function testTaskShareCongestsLikeGasShare() public {
        setUpRegistry();
        IRegistryFacet registry = IRegistryFacet(diamond);

        assertEq(registry.calculateAutomationFeeMultiplierForCommittedOccupancy(0, CAPACITY), FULL_RATE);
        assertEq(registry.calculateAutomationFeeMultiplierForCommittedOccupancy(GAS_CAP, 0), FULL_RATE);
        assertEq(
            registry.calculateAutomationFeeMultiplierForCommittedOccupancy(0, 6),
            registry.calculateAutomationFeeMultiplierForCommittedOccupancy(GAS_CAP * 6 / 10, 0),
            "60% of slots prices as 60% of gas"
        );
        assertEq(registry.calculateAutomationFeeMultiplierForCommittedOccupancy(0, 5), BASE_FEE, "50% is not congested");
    }

    /// @dev The larger of the two shares sets the rate.
    function testCongestionUsesTheLargerShare() public {
        setUpRegistry();
        IRegistryFacet registry = IRegistryFacet(diamond);

        uint128 at80 = registry.calculateAutomationFeeMultiplierForCommittedOccupancy(GAS_CAP * 8 / 10, 0);
        assertEq(registry.calculateAutomationFeeMultiplierForCommittedOccupancy(GAS_CAP * 8 / 10, 6), at80);
        assertEq(registry.calculateAutomationFeeMultiplierForCommittedOccupancy(GAS_CAP * 6 / 10, 8), at80);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: Charging :::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev With every slot taken, each small task is charged a whole slot at the full-registry
    /// rate, so the tasks together pay the full-registry rate for the whole gas cap.
    function testEverySlotTakenChargesEachTaskAWholeSlot() public {
        setUpRegistry();
        uint256 before = wsupra.balanceOf(owner);
        uint256 upFront = uint256(CAPACITY) * (FLAT_FEE + FEE_CAP);
        uint64[] memory ids = new uint64[](CAPACITY);
        for (uint256 i; i < CAPACITY; i++) {
            ids[i] = registerSmallTask();
        }
        assertEq(IRegistryViewFacet(diamond).getTasksCommittedForNextCycle(), CAPACITY);

        processCycleTransition(diamond, ids);

        uint256 perTask = cycleFee(FULL_RATE, FLOOR_GAS);
        assertEq(perTask, 341.71875 ether, "5.6953125 SUPRA/s * 600 s * 250,000 / 2,500,000");
        assertEq(before - wsupra.balanceOf(owner) - upFront, perTask * CAPACITY, "charged");
        assertEq(IRegistryViewFacet(diamond).getCycleLockedFees(), perTask * CAPACITY, "locked");
        assertEq(IRegistryFacet(diamond).calculateAutomationFeeMultiplierForCurrentCycle(), FULL_RATE);
    }

    /// @dev With the task share at the threshold, a task is charged its own gas at the base rate.
    function testTaskShareAtTheThresholdChargesOwnGas() public {
        setUpRegistry();
        uint256 before = wsupra.balanceOf(owner);
        registerAndActivate(CAPACITY / 2);

        uint256 perTask = cycleFee(BASE_FEE, SMALL_GAS);
        assertEq(perTask, 6 ether, "0.5 SUPRA/s * 600 s * 50,000 / 2,500,000");
        uint256 upFront = uint256(CAPACITY / 2) * (FLAT_FEE + FEE_CAP);
        assertEq(before - wsupra.balanceOf(owner) - upFront, perTask * (CAPACITY / 2));
    }

    /// @dev Just above the threshold, a task is billed part of a slot at the congested rate:
    /// at 60% of the slots, 50,000 + (250,000 - 50,000) * 0.2 = 90,000 gas.
    function testTaskShareAboveTheThresholdChargesPartOfASlot() public {
        setUpRegistry();
        uint256 before = wsupra.balanceOf(owner);
        registerAndActivate(6);

        uint128 rate = IRegistryFacet(diamond).calculateAutomationFeeMultiplierForCurrentCycle();
        assertEq(rate, IRegistryFacet(diamond).calculateAutomationFeeMultiplierForCommittedOccupancy(GAS_CAP * 6 / 10, 0));
        uint256 upFront = 6 * uint256(FLAT_FEE + FEE_CAP);
        assertEq(before - wsupra.balanceOf(owner) - upFront, cycleFee(rate, 90_000) * 6);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: Counters :::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev The task counts follow the gas commitment: registration and cancellation change the
    /// next-cycle count, the transition fixes the current-cycle snapshot and rebuilds the
    /// next-cycle count from the survivors, and a stop changes only the next-cycle count.
    function testTaskCountsFollowTheGasCommitment() public {
        setUpRegistry();
        IRegistryViewFacet views = IRegistryViewFacet(diamond);

        uint64 a = registerSmallTask();
        uint64 b = registerSmallTask();
        uint64 c = registerSmallTask();
        assertEq(views.getTasksCommittedForNextCycle(), 3);

        uint64[] memory cancel = new uint64[](1);
        cancel[0] = c;
        vm.prank(owner);
        IRegistryFacet(diamond).cancelTasks(cancel);
        assertEq(views.getTasksCommittedForNextCycle(), 2, "a cancelled PENDING task is released");

        uint64[] memory ids = new uint64[](2);
        ids[0] = a;
        ids[1] = b;
        processCycleTransition(diamond, ids);
        assertEq(views.getTasksCommittedForCurrentCycle(), 2, "snapshot of the cycle entered");
        assertEq(views.getTasksCommittedForNextCycle(), 2, "rebuilt from the survivors");

        uint64[] memory stop = new uint64[](1);
        stop[0] = a;
        vm.prank(owner);
        IRegistryFacet(diamond).stopTasks(stop);
        assertEq(views.getTasksCommittedForNextCycle(), 1, "a stop releases the next cycle");
        assertEq(views.getTasksCommittedForCurrentCycle(), 2, "the snapshot does not change in the cycle");
        assertEq(views.getGasCommittedForNextCycle(), SMALL_GAS);
    }

    /// @dev A task that expires within the cycle being entered is not committed to the one after.
    function testATaskExpiringInTheNewCycleIsNotCommittedToTheNext() public {
        setUpRegistry();
        bytes[] memory aux;
        vm.prank(owner);
        IRegistryFacet(diamond).register(
            createPayload(0, address(wsupra), abi.encodeCall(wsupra.withdraw, 1)),
            createPredicate(diamond),
            uint64(block.timestamp) + CYCLE + CYCLE / 2,
            SMALL_GAS,
            uint128(1 gwei),
            FEE_CAP,
            0,
            aux
        );
        uint64[] memory ids = new uint64[](1);
        ids[0] = 0;
        processCycleTransition(diamond, ids);

        assertEq(IRegistryViewFacet(diamond).getTasksCommittedForCurrentCycle(), 1);
        assertEq(IRegistryViewFacet(diamond).getTasksCommittedForNextCycle(), 0);
        assertEq(IRegistryViewFacet(diamond).getGasCommittedForNextCycle(), 0);
    }

    /// @dev Suspension clears both task counts, as it clears the gas commitments.
    function testSuspensionClearsTheTaskCounts() public {
        setUpRegistry();
        uint64[] memory ids = registerAndActivate(3);
        (uint64 index, , , ) = ICoreFacet(diamond).getCycleInfo();

        vm.prank(admin);
        ICoreFacet(diamond).disableAutomation();
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamond).processTasks(index, ids);

        assertEq(IRegistryViewFacet(diamond).getTasksCommittedForCurrentCycle(), 0);
        assertEq(IRegistryViewFacet(diamond).getTasksCommittedForNextCycle(), 0);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: Refunds ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev A stop during a cycle whose tasks were billed on the ramp unlocks exactly the fee the
    /// transition charged and refunds half its unused part. Stops after it unlock the same amount:
    /// the fee is recomputed from the cycle's snapshot, which a stop does not change.
    function testStopsUnlockExactlyTheChargedFee() public {
        setUpRegistry();
        uint64[] memory ids = registerAndActivate(CAPACITY);
        uint256 perTask = cycleFee(FULL_RATE, FLOOR_GAS);
        assertEq(IRegistryViewFacet(diamond).getCycleLockedFees(), perTask * CAPACITY);

        (, uint64 start, uint64 duration, ) = ICoreFacet(diamond).getCycleInfo();
        vm.warp(start + duration / 4);
        uint256 residualRefund = (perTask * 3 / 4) / 2;

        for (uint256 i; i < 3; i++) {
            uint64[] memory stop = new uint64[](1);
            stop[0] = ids[i];
            uint256 ownerBefore = wsupra.balanceOf(owner);
            vm.prank(owner);
            IRegistryFacet(diamond).stopTasks(stop);

            assertEq(
                IRegistryViewFacet(diamond).getCycleLockedFees(),
                perTask * (CAPACITY - i - 1),
                "the charged fee is unlocked"
            );
            assertApproxEqAbs(
                wsupra.balanceOf(owner) - ownerBefore,
                FEE_CAP + residualRefund,
                1,
                "deposit and half the unused fee"
            );
        }
    }

    /// @dev A removal by the registry owner unlocks the charged fee as a stop does.
    function testGovernanceRemovalUnlocksExactlyTheChargedFee() public {
        setUpRegistry();
        uint64[] memory ids = registerAndActivate(CAPACITY);
        uint256 perTask = cycleFee(FULL_RATE, FLOOR_GAS);

        uint64[] memory remove = new uint64[](2);
        remove[0] = ids[0];
        remove[1] = ids[1];
        vm.prank(admin);
        IConfigFacet(diamond).removeTasks(remove);

        assertEq(IRegistryViewFacet(diamond).getCycleLockedFees(), perTask * (CAPACITY - 2));
        assertEq(IRegistryViewFacet(diamond).getTasksCommittedForNextCycle(), CAPACITY - 2);
    }

    /// @dev Suspension at the start of a cycle refunds every task its whole charged fee, which
    /// leaves no locked fee behind.
    function testSuspensionRefundsTheWholeChargedFee() public {
        setUpRegistry();
        uint64[] memory ids = registerAndActivate(CAPACITY);
        (uint64 index, , , ) = ICoreFacet(diamond).getCycleInfo();
        uint256 ownerBefore = wsupra.balanceOf(owner);

        vm.prank(admin);
        ICoreFacet(diamond).disableAutomation();
        vm.prank(LibUtils.VM_SIGNER);
        ICoreFacet(diamond).processTasks(index, ids);

        assertEq(IRegistryViewFacet(diamond).getCycleLockedFees(), 0);
        assertEq(
            wsupra.balanceOf(owner) - ownerBefore,
            uint256(CAPACITY) * (cycleFee(FULL_RATE, FLOOR_GAS) + FEE_CAP)
        );
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Estimate ::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev The registration estimate for the task that fills the registry is the fee the
    /// transition charges it when no other task registers in between.
    function testEstimateForTheLastSlotIsTheChargedFee() public {
        setUpRegistry();
        uint64[] memory ids = new uint64[](CAPACITY);
        for (uint256 i; i + 1 < CAPACITY; i++) {
            ids[i] = registerSmallTask();
        }
        uint128 estimate = IRegistryFacet(diamond).estimateAutomationFee(SMALL_GAS);
        assertEq(estimate, cycleFee(FULL_RATE, FLOOR_GAS));
        assertEq(
            IRegistryFacet(diamond).estimateAutomationFeeWithCommittedOccupancy(
                SMALL_GAS, SMALL_GAS * (CAPACITY - 1), CAPACITY - 1
            ),
            estimate
        );

        ids[CAPACITY - 1] = registerSmallTask();
        uint256 before = wsupra.balanceOf(owner);
        processCycleTransition(diamond, ids);
        assertEq(before - wsupra.balanceOf(owner), uint256(estimate) * CAPACITY);
    }

    /// @dev A registration whose fee cap is below the estimate for the occupancy it joins is
    /// refused with that estimate.
    function testRegistrationRefusesACapBelowTheSlotPricedEstimate() public {
        setUpRegistry();
        for (uint256 i; i + 1 < CAPACITY; i++) {
            registerSmallTask();
        }
        uint128 estimate = IRegistryFacet(diamond).estimateAutomationFee(SMALL_GAS);
        bytes[] memory aux;
        vm.expectRevert(abi.encodeWithSelector(IRegistryFacet.InsufficientFeeCapForCycle.selector, estimate));
        vm.prank(owner);
        IRegistryFacet(diamond).register(
            createPayload(0, address(wsupra), abi.encodeCall(wsupra.withdraw, 1)),
            createPredicate(diamond),
            uint64(block.timestamp) + TASK_DURATION_CAP,
            SMALL_GAS,
            uint128(1 gwei),
            estimate - 1,
            0,
            aux
        );
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Config ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev A buffered capacity applies to the next cycle's estimate and must hold the tasks
    /// already committed to it.
    function testConfigBufferSetsTheNextCycleCapacity() public {
        setUpRegistry();
        assertEq(IRegistryViewFacet(diamond).getNextCycleTaskCapacity(), CAPACITY);
        registerSmallTask();
        registerSmallTask();

        vm.prank(admin);
        vm.expectRevert(IConfigFacet.UnacceptableTaskCapacity.selector);
        updateCapacity(1);

        vm.prank(admin);
        updateCapacity(2);
        assertEq(IRegistryViewFacet(diamond).getNextCycleTaskCapacity(), 2);
        // Two tasks fill the next cycle's two slots: the full-registry rate, and each task is
        // billed a slot's worth of gas, GAS_CAP / 2.
        assertEq(
            IRegistryFacet(diamond).estimateAutomationFeeWithCommittedOccupancy(SMALL_GAS, SMALL_GAS, 1),
            cycleFee(FULL_RATE, GAS_CAP / 2)
        );
    }

    /// @dev After the capacity of the next cycle is lowered to the tasks already committed to it,
    /// a further registration is refused although the active capacity has room.
    function testRegistrationIsRefusedAtTheNextCycleCapacity() public {
        setUpRegistry();
        registerSmallTask();
        registerSmallTask();
        vm.prank(admin);
        updateCapacity(2);

        bytes[] memory aux;
        vm.expectRevert(IRegistryFacet.TaskCapacityReached.selector);
        vm.prank(owner);
        IRegistryFacet(diamond).register(
            createPayload(0, address(wsupra), abi.encodeCall(wsupra.withdraw, 1)),
            createPredicate(diamond),
            uint64(block.timestamp) + TASK_DURATION_CAP,
            SMALL_GAS,
            uint128(1 gwei),
            FEE_CAP,
            0,
            aux
        );
    }

    /// @dev A cycle that starts with no task registered reports no current-cycle commitment.
    function testAnEmptyCycleHasNoCurrentCycleCommitment() public {
        setUpRegistry();
        uint64[] memory ids = registerAndActivate(3);
        assertEq(IRegistryViewFacet(diamond).getTasksCommittedForCurrentCycle(), 3);

        vm.prank(owner);
        IRegistryFacet(diamond).stopTasks(ids);
        endCycleAsVmSigner(diamond);

        (, , , LibCommon.CycleState state) = ICoreFacet(diamond).getCycleInfo();
        assertEq(uint8(state), uint8(LibCommon.CycleState.STARTED), "an empty registry starts the next cycle directly");
        assertEq(IRegistryViewFacet(diamond).getTasksCommittedForCurrentCycle(), 0);
        assertEq(IRegistryViewFacet(diamond).getGasCommittedForCurrentCycle(), 0);
        assertEq(IRegistryFacet(diamond).calculateAutomationFeeMultiplierForCurrentCycle(), BASE_FEE);
    }

    /// @dev The estimate's committed task count is an external input; the largest uint32 is
    /// estimated as a full registry rather than reverting.
    function testEstimateAcceptsTheLargestTaskCount() public {
        setUpRegistry();
        assertEq(
            IRegistryFacet(diamond).estimateAutomationFeeWithCommittedOccupancy(SMALL_GAS, 0, type(uint32).max),
            cycleFee(FULL_RATE, FLOOR_GAS)
        );
    }

    /// @dev The estimate measures the occupancy against the next cycle's limits and prices it
    /// with the active fee parameters: a buffered lower capacity changes the estimate, a buffered
    /// threshold does not until it is applied.
    function testEstimateUsesNextCycleLimitsAndActiveFeeParameters() public {
        setUpRegistry();
        for (uint256 i; i < 5; i++) {
            registerSmallTask();
        }
        uint128 before = IRegistryFacet(diamond).estimateAutomationFee(SMALL_GAS);
        assertEq(before, cycleFee(IRegistryFacet(diamond).calculateAutomationFeeMultiplierForCommittedOccupancy(0, 6), 90_000));

        // A buffered threshold of 30% leaves the estimate unchanged.
        vm.prank(admin);
        IConfigFacet(diamond).updateConfigBuffer(
            TASK_DURATION_CAP, GAS_CAP, BASE_FEE, FLAT_FEE, 30, CONGESTION_FEE, EXPONENT, EXPONENT,
            CAPACITY, CYCLE, 180 days, GAS_CAP, 5
        );
        assertEq(IRegistryFacet(diamond).estimateAutomationFee(SMALL_GAS), before);

        // A buffered capacity of 6 makes the sixth task fill the next cycle.
        vm.prank(admin);
        updateCapacity(6);
        assertEq(
            IRegistryFacet(diamond).estimateAutomationFee(SMALL_GAS),
            cycleFee(FULL_RATE, GAS_CAP / 6)
        );
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: System tasks :::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev The registry starts with 5 system-task slots; `bob` is an authorized submitter.
    function registerSystemTask() internal {
        if (!IRegistryFacet(diamond).isAuthorizedSubmitter(bob)) {
            vm.prank(admin);
            IConfigFacet(diamond).grantAuthorization(bob);
        }
        registerGst(diamond, 30 days);
    }

    /// @dev After the system-task capacity of the next cycle is lowered to the system tasks
    /// registered, a further system task is refused although the active capacity has room.
    function testSystemTaskRegistrationIsRefusedAtTheNextCycleCapacity() public {
        setUpRegistry();
        registerSystemTask();
        registerSystemTask();
        vm.prank(admin);
        updateCapacities(CAPACITY, 2);
        assertEq(IRegistryViewFacet(diamond).getNextCycleSysTaskCapacity(), 2);

        bytes[] memory aux;
        vm.expectRevert(IRegistryFacet.TaskCapacityReached.selector);
        vm.prank(bob);
        IRegistryFacet(diamond).registerSystemTask(
            createPayload(0, address(wsupra), abi.encodeCall(wsupra.withdraw, 1)),
            createPredicate(diamond),
            uint64(block.timestamp + 30 days),
            uint128(100_000),
            2,
            aux
        );
    }

    /// @dev A buffered system-task capacity must hold the system tasks already registered.
    function testConfigBufferRefusesASysCapacityBelowTheRegisteredSystemTasks() public {
        setUpRegistry();
        registerSystemTask();
        registerSystemTask();
        registerSystemTask();

        vm.prank(admin);
        vm.expectRevert(IConfigFacet.UnacceptableSysTaskCapacity.selector);
        updateCapacities(CAPACITY, 2);

        vm.prank(admin);
        updateCapacities(CAPACITY, 3);
        assertEq(IRegistryViewFacet(diamond).getNextCycleSysTaskCapacity(), 3);
    }

    function updateCapacity(uint16 _capacity) internal {
        updateCapacities(_capacity, 5);
    }

    function updateCapacities(uint16 _capacity, uint16 _sysCapacity) internal {
        IConfigFacet(diamond).updateConfigBuffer(
            TASK_DURATION_CAP,
            GAS_CAP,
            BASE_FEE,
            FLAT_FEE,
            THRESHOLD,
            CONGESTION_FEE,
            EXPONENT,
            EXPONENT,
            _capacity,
            CYCLE,
            180 days,
            GAS_CAP,
            _sysCapacity
        );
    }
}
