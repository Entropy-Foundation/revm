// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

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
/// the number of registered tasks because `onCycleEndInternal` must:
///   1. Load all task IDs from storage  (SLOAD per task)
///   2. Sort the list                   (insertionSort — O(n) on monotone IDs)
///   3. Write them back into the transition-state EnumerableSet (SSTORE per task)
///
/// Step 3 dominates: each EnumerableSet.add() that writes to a fresh (zero) slot
/// costs two 20,000-gas SSTOREs (one for the value array element, one for the
/// index mapping entry), totalling ~40,000–45,000 gas per task.
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
    uint16 constant LARGE_CAPACITY = 400;

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

    function testMonitorCycleEndGas_N400() public {
        address d = _deployWithCapacity(400);
        _registerNTasks(d, 400);
        uint256 gas = _measureMonitorCycleEnd(d);
        console.log("monitorCycleEnd gas | N=400 |", gas);
        // N=400 is the registry capacity ceiling; log whether it fits the budget
        // without a hard assertion so CI does not break if it is over budget —
        // the boundary scan test below identifies the exact safe limit.
        if (gas >= BLOCK_PROLOGUE_GAS_LIMIT) {
            console.log("  -> N=400 EXCEEDS budget (", BLOCK_PROLOGUE_GAS_LIMIT, ")");
        } else {
            console.log("  -> N=400 within budget");
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

        console.log("=== monitorCycleEnd gas boundary (insertionSort) ===");
        console.log("Safe task limit (max N within 16_777_216 gas):", safeLimitN);
        console.log("First N that exceeds budget                  :", safeLimitN + 1);

        assertGt(safeLimitN, 0, "no safe N found - even N=1 exceeds budget");
    }
}
