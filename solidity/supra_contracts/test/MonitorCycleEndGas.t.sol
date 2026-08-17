// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {Deployment, InitParams, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";

/// @notice Gas-scaling tests for monitorCycleEnd / onCycleEndInternal.
///
/// The Supra native layer calls `monitorCycleEnd` from `BlockMeta::blockPrologue`
/// with a hard gas budget of 16_777_216.  The function's cost scales linearly with
/// the number of registered tasks, regardless of removal history, because
/// `onCycleEndInternal` must:
///   1. Filter+compact RegistryState.orderedTaskIds into the alive-only ascending
///      list (LibCore.buildAliveOrderedTaskIds — O(n), one SLOAD per task)
///   2. Write the result into the transition state's `expectedTasksToBeProcessed` (SSTORE per task)
///
/// Step 2 dominates. `expectedTasksToBeProcessed` used to be an EnumerableSet.UintSet,
/// whose add() writes two 20,000-gas SSTOREs per task (one for the value array element,
/// one for the O(1)-lookup index mapping entry) — ~40,000-45,000 gas/task. That mapping
/// was never actually queried (the field is only ever read back sequentially via
/// length/at), so the field was changed to a plain `uint256[]`: a single push() per task
/// now costs one SSTORE instead of two, roughly halving the per-task cost to
/// ~20,000-22,000 gas (see LibCore.updateExpectedTasks and its NatSpec).
///
/// This test file answers two questions empirically:
///   A. What gas does monitorCycleEnd consume for a given task count?
///   B. At what task count does the cumulative gas exceed 16_777_216?
///
/// Every test logs its gas figures so the output of `forge test -vv` can be used
/// as a reference when sizing the task registry capacity.
contract MonitorCycleEndGasTest is BaseDiamondTest {

    /// @dev Hard gas budget imposed by Supra's blockPrologue on this call path.
    uint256 constant BLOCK_PROLOGUE_GAS_LIMIT = 16_777_216;

    /// @dev Task capacity for the shared diamond used by the N050/N100/N150 point tests
    ///      and by the BoundaryScan, which searches [1, LARGE_CAPACITY].
    ///      N200-N400 tests each deploy a diamond with a capacity matching their own N,
    ///      so they are unaffected by this constant.
    ///      uint16 matches the type of InitParams.taskCapacity.
    uint16 constant LARGE_CAPACITY = 1000;

    // ────────────────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Deploy a fresh diamond whose task capacity is set to `_capacity`.
    ///      Using a dedicated diamond per test keeps each measurement independent —
    ///      storage that was touched by a prior test would be "warm" and distort
    ///      the SLOAD/SSTORE gas figures.
    function _deployWithCapacity(uint16 _capacity) internal returns (address diamond) {
        InitParams memory p = LibDiamondUtils.defaultInitParams();
        p.taskCapacity = _capacity;
        // Keep cycle short so vm.warp does not need a large jump.
        p.cycleDurationSecs = 1200;
        // Raise the registry gas cap so it never blocks registration for large N.
        // LARGE_CAPACITY * 100_000 (maxGasAmount per task) needs to fit in this cap.
        // The production cap is a separate concern; here we only want to measure
        // monitorCycleEnd gas without being gated by the registration cap.
        p.registryMaxGasCap = uint128(uint256(_capacity) * 100_000 + 1_000_000);

        vm.startPrank(admin);
        Deployment memory d = LibDiamondUtils.deploy(admin, address(erc20Supra), p);
        diamond = d.diamond;
        vm.stopPrank();
    }

    /// @dev Register `_n` USTs on `_diamond`.
    ///
    /// Token flow:
    ///   - Each registration deducts `flatRegistrationFeeWei` (1 ether) from alice's
    ///     ERC20 balance.  We deposit `_n * 2 ether` ETH upfront so alice has enough
    ///     ERC20 for all registrations without running dry.
    ///   - The automation fee cap (60.1 ether) is per-task but is only *charged* during
    ///     processTasks, not during monitorCycleEnd.  It does not affect this gas test.
    function _registerNTasks(address _diamond, uint256 _n) internal {
        // Each registration deducts two amounts from alice's ERC20 balance:
        //   - flatRegistrationFeeWei = 1 ether  (charged and collected)
        //   - automationFeeCapForCycle = 60.1 ether (locked as deposit)
        // Total per task: 61.1 ether.  We deposit _n * 62 ether to include a
        // small per-task buffer on top of the exact 61.1 ether requirement.
        uint256 depositAmount = _n * 62 ether;
        vm.deal(alice, depositAmount + 100 ether);

        bytes[] memory auxData;
        bytes memory payload = createPayload(
            0,
            address(erc20SupraHandler),
            abi.encodeCall(erc20SupraHandler.withdraw, 100)
        );
        bytes memory predicate = createPredicate(_diamond);

        vm.startPrank(alice);
        // Single bulk deposit — mints depositAmount of ERC20 to alice.
        erc20SupraHandler.deposit{value: depositAmount}();
        erc20Supra.approve(_diamond, type(uint256).max);

        // Expiry is set to 1 day from the current block.timestamp.
        // Using 3600 (1 hour) was too close to the cycle end (1200 s) when
        // block.timestamp accumulates across binary-scan iterations.
        // 86400 s is well within the 7-day taskDurationCapSecs cap and is always
        // many times larger than cycleDurationSecs (1200 s), so the
        // TaskExpiresBeforeNextCycle check (expiryTime > cycleEndTime) always passes
        // regardless of how many vm.warp calls have occurred before registration.
        uint64 expiry = uint64(block.timestamp + 86400);

        for (uint256 i = 0; i < _n; i++) {
            IRegistryFacet(_diamond).register(
                payload,
                predicate,
                expiry,
                uint128(100_000),                  // maxGasAmount
                uint128(4 gwei),                   // gasPriceCap
                uint128(60.1 ether),               // automationFeeCapForCycle
                2,                                 // priority
                auxData
            );
        }
        vm.stopPrank();
    }

    /// @dev Advance time past the cycle boundary, call monitorCycleEnd as the
    ///      VM signer, and return the gas consumed.
    ///
    ///      Gas metering is done with gasleft() brackets rather than Forge's
    ///      `vm.pauseGasMetering` so that storage-access costs (SLOAD/SSTORE)
    ///      are captured faithfully — pauseGasMetering would zero those out.
    ///
    ///      The measured value is slightly higher than the bare function cost
    ///      because the CALL opcode overhead and return data copying are included.
    ///      This conservative over-count is appropriate: the production caller
    ///      (blockPrologue) incurs the same overhead.
    function _measureMonitorCycleEnd(address _diamond) internal returns (uint256 gasUsed) {
        // Warp to exactly the cycle boundary so the end condition triggers.
        (, uint64 startTime, uint64 durationSecs,) = ICoreFacet(_diamond).getCycleInfo();
        vm.warp(startTime + durationSecs);

        // monitorCycleEnd checks tx.origin, not msg.sender alone.
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);

        uint256 before = gasleft();
        ICoreFacet(_diamond).monitorCycleEnd();
        gasUsed = before - gasleft();
    }

    /// @dev Overwrites `RegistryState.orderedTaskIds` (the append-only array
    ///      `buildAliveOrderedTaskIds`, LibCore.sol, actually reads at cycle end) with
    ///      `n-1, n-2, ..., 0` (fully descending) instead of the `0..n-1` (ascending)
    ///      order `_registerNTasks` leaves it in.
    ///
    ///      This is a regression guard: `orderedTaskIds` is append-only in production
    ///      (LibRegistry.createAndStoreTask) and task IDs are assigned strictly
    ///      monotonically, so it can never actually become descending on its own. Forcing
    ///      it here proves `buildAliveOrderedTaskIds`'s cost has no dependency on element
    ///      order (it's a filter, not a sort) — this test's result should match
    ///      testMonitorCycleEndGas_BoundaryScan's regardless of input order.
    ///
    ///      Slot derivation (confirmed via `forge inspect StorageLayoutProbe
    ///      storage-layout`, not hand-computed):
    ///        AppStorage.registry              -> slot 6  (mapping(uint256 => RegistryState))
    ///        RegistryState.orderedTaskIds     -> slot 11 (offset within RegistryState, plain uint256[])
    ///      where the contract content is:
    ///
    ///         // SPDX-License-Identifier: MIT
    ///         pragma solidity 0.8.34;
    ///
    ///         import {AppStorage} from "./libraries/LibAppStorage.sol";
    ///
    ///         /// @dev Scratch contract used only to extract `forge inspect ... storage-layout`
    ///         ///      output for AppStorage's nested struct field offsets. Not part of the
    ///         ///      diamond or any deployment — safe to delete after use.
    ///         contract StorageLayoutProbe {
    ///             AppStorage internal s;
    ///         }
    function _setOrderedTaskIdsDescending(address _diamond, uint256 _n) internal {
        uint256 registryStateBase = uint256(keccak256(abi.encode(uint256(0), uint256(6))));
        uint256 lengthSlot = registryStateBase + 11;
        uint256 dataBase = uint256(keccak256(abi.encode(lengthSlot)));

        vm.store(_diamond, bytes32(lengthSlot), bytes32(_n));
        for (uint256 i = 0; i < _n; i++) {
            // Registered task IDs are 0..n-1 (ascending); write them back descending
            // (n-1, n-2, ..., 0) so the array holds exactly the same value set,
            // just in the fully-reversed order.
            vm.store(_diamond, bytes32(dataBase + i), bytes32((_n - 1) - i));
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Individual measurements
    //
    // Each test is a self-contained: fresh diamond, register N tasks, measure.
    // Running them under `forge test -vv` prints the gas figures.
    // ────────────────────────────────────────────────────────────────────────

    function testMonitorCycleEndGas_N050() public {
        address d = _deployWithCapacity(LARGE_CAPACITY);
        _registerNTasks(d, 50);
        uint256 gas = _measureMonitorCycleEnd(d);
        console.log("monitorCycleEnd gas | N=050 |", gas);
        assertLt(gas, BLOCK_PROLOGUE_GAS_LIMIT, "N=50 must be within gas budget");
    }

    function testMonitorCycleEndGas_N100() public {
        address d = _deployWithCapacity(LARGE_CAPACITY);
        _registerNTasks(d, 100);
        uint256 gas = _measureMonitorCycleEnd(d);
        console.log("monitorCycleEnd gas | N=100 |", gas);
        assertLt(gas, BLOCK_PROLOGUE_GAS_LIMIT, "N=100 must be within gas budget");
    }

    function testMonitorCycleEndGas_N150() public {
        address d = _deployWithCapacity(LARGE_CAPACITY);
        _registerNTasks(d, 150);
        uint256 gas = _measureMonitorCycleEnd(d);
        console.log("monitorCycleEnd gas | N=150 |", gas);
        assertLt(gas, BLOCK_PROLOGUE_GAS_LIMIT, "N=150 must be within gas budget");
    }

    function testMonitorCycleEndGas_N200() public {
        // Deploy with capacity exactly matching N so the task-count limit never
        // triggers, regardless of the LARGE_CAPACITY constant used by smaller tests.
        address d = _deployWithCapacity(200);
        _registerNTasks(d, 200);
        uint256 gas = _measureMonitorCycleEnd(d);
        console.log("monitorCycleEnd gas | N=200 |", gas);
        assertLt(gas, BLOCK_PROLOGUE_GAS_LIMIT, "N=200 must be within gas budget");
    }

    function testMonitorCycleEndGas_N250() public {
        address d = _deployWithCapacity(250);
        _registerNTasks(d, 250);
        uint256 gas = _measureMonitorCycleEnd(d);
        console.log("monitorCycleEnd gas | N=250 |", gas);
        assertLt(gas, BLOCK_PROLOGUE_GAS_LIMIT, "N=250 must be within gas budget");
    }

    function testMonitorCycleEndGas_N300() public {
        address d = _deployWithCapacity(300);
        _registerNTasks(d, 300);
        uint256 gas = _measureMonitorCycleEnd(d);
        console.log("monitorCycleEnd gas | N=300 |", gas);
        assertLt(gas, BLOCK_PROLOGUE_GAS_LIMIT, "N=300 must be within gas budget");
    }

    function testMonitorCycleEndGas_N350() public {
        address d = _deployWithCapacity(350);
        _registerNTasks(d, 350);
        uint256 gas = _measureMonitorCycleEnd(d);
        console.log("monitorCycleEnd gas | N=350 |", gas);
        assertLt(gas, BLOCK_PROLOGUE_GAS_LIMIT, "N=350 must be within gas budget");
    }

    function observeMonitorCycleEndGas_N720() public {
        address d = _deployWithCapacity(720);
        _registerNTasks(d, 720);
        uint256 gas = _measureMonitorCycleEnd(d);
        console.log("monitorCycleEnd gas | N=720 |", gas);
        // No hard assertion: the boundary scan below identifies the exact safe limit
        // (see testMonitorCycleEndGas_BoundaryScan), which sits well above the production
        // capacity of 200 (taskCapacity + sysTaskCapacity, LibDiamondUtils.sol).
        if (gas >= BLOCK_PROLOGUE_GAS_LIMIT) {
            console.log("  -> N=720 EXCEEDS budget (", BLOCK_PROLOGUE_GAS_LIMIT, ")");
        } else {
            console.log("  -> N=720 within budget");
        }
    }

    function testMonitorCycleEndGas_N800() public {
        address d = _deployWithCapacity(800);
        _registerNTasks(d, 800);
        uint256 gas = _measureMonitorCycleEnd(d);
        console.log("monitorCycleEnd gas | N=800 |", gas);
        // N=800 is the registry capacity ceiling; log whether it fits the budget
        // without a hard assertion so CI does not break if it is over budget —
        // the boundary scan test below identifies the exact safe limit.
        if (gas >= BLOCK_PROLOGUE_GAS_LIMIT) {
            console.log("  -> N=800 EXCEEDS budget (", BLOCK_PROLOGUE_GAS_LIMIT, ")");
        } else {
            console.log("  -> N=800 within budget");
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Boundary scan
    //
    // Binary-searches for the largest N such that monitorCycleEnd stays within
    // BLOCK_PROLOGUE_GAS_LIMIT, using the full [1, LARGE_CAPACITY] range.
    //
    // This is the canonical test for answering "what is the safe task limit?".
    // Run it once and read the logged result; rerun after any algorithm change.
    // ────────────────────────────────────────────────────────────────────────
    function testMonitorCycleEndGas_BoundaryScan() public {
        // Deploy the diamond ONCE before the search loop and snapshot its clean state.
        //
        // Rationale for deploy-once: previous versions deployed inside the loop, paying
        // ~12.7 M gas per iteration for facet deployments.  With LARGE_CAPACITY = 198 and
        // ~8 binary-search iterations, that added ~100 M gas to the total — pushing the
        // test past the 1 billion gas ceiling even after raising block_gas_limit.
        //
        // The snapshot is taken AFTER deployment so block.timestamp already reflects a
        // real cycle-start reference ("proper cycle start time" precondition).  Every
        // binary-search iteration reverts to this snapshot, which:
        //   - removes all task registrations from the previous probe
        //   - resets block.timestamp to the clean post-deployment value, preventing
        //     timestamp drift from accumulated vm.warp calls (which would otherwise cause
        //     TaskExpiresBeforeNextCycle once enough cycles have elapsed)
        //
        // Local Solidity variables (lo, hi, safeLimitN, mid, gas) are stack-allocated
        // and are NOT part of EVM state, so they survive vm.revertToState unchanged.
        // vm.revertToState (not revertToStateAndDelete) keeps the snapshot alive for
        // reuse in subsequent iterations.
        address d = _deployWithCapacity(LARGE_CAPACITY);
        uint256 cleanSnap = vm.snapshotState();

        uint256 lo = 1;
        uint256 hi = LARGE_CAPACITY;
        uint256 safeLimitN = 0;

        while (lo <= hi) {
            uint256 mid = (lo + hi) / 2;

            _registerNTasks(d, mid);
            uint256 gas = _measureMonitorCycleEnd(d);

            vm.revertToState(cleanSnap);

            if (gas < BLOCK_PROLOGUE_GAS_LIMIT) {
                safeLimitN = mid;
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }

        console.log("=== monitorCycleEnd gas boundary (buildAliveOrderedTaskIds, ascending taskIdList) ===");
        console.log("Safe task limit (max N within 16_777_216 gas):", safeLimitN);
        console.log("First N that exceeds budget                  :", safeLimitN + 1);

        assertGt(safeLimitN, 0, "no safe N found - even N=1 exceeds budget");
    }

    // ────────────────────────────────────────────────────────────────────────
    // Boundary scan — reverse-sorted orderedTaskIds (regression guard)
    //
    // Identical binary search to testMonitorCycleEndGas_BoundaryScan, except
    // that after each probe's registrations, orderedTaskIds' underlying array is
    // overwritten (via _setOrderedTaskIdsDescending) to be fully descending
    // instead of the ascending order registration naturally produces. Since
    // buildAliveOrderedTaskIds (LibCore.sol) is a linear filter, not a sort, its
    // cost has no dependency on element order — this test exists to prove that
    // property empirically and catch any future regression back toward an
    // order-sensitive algorithm. Expect this to report the same safe limit as
    // testMonitorCycleEndGas_BoundaryScan.
    // ────────────────────────────────────────────────────────────────────────
    function testMonitorCycleEndGas_BoundaryScan_ReverseSorted() public {
        address d = _deployWithCapacity(LARGE_CAPACITY);
        uint256 cleanSnap = vm.snapshotState();

        uint256 lo = 1;
        uint256 hi = LARGE_CAPACITY;
        uint256 safeLimitN = 0;

        while (lo <= hi) {
            uint256 mid = (lo + hi) / 2;

            _registerNTasks(d, mid);
            _setOrderedTaskIdsDescending(d, mid);
            uint256 gas = _measureMonitorCycleEnd(d);

            vm.revertToState(cleanSnap);

            if (gas < BLOCK_PROLOGUE_GAS_LIMIT) {
                safeLimitN = mid;
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }

        console.log("=== monitorCycleEnd gas boundary (buildAliveOrderedTaskIds, FULLY REVERSE-SORTED orderedTaskIds) ===");
        console.log("Safe task limit (max N within 16_777_216 gas):", safeLimitN);
        console.log("First N that exceeds budget                  :", safeLimitN + 1);

        assertGt(safeLimitN, 0, "no safe N found - even N=1 exceeds budget");
    }
}
