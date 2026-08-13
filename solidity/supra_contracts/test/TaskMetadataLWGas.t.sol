// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {Deployment, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";
import {ERC20SupraHandler} from "../src/ERC20SupraHandler.sol";

/// @notice Gas-comparison tests proving that task charging/lifecycle branches which do NOT
/// delete the task from storage (dropOrChargeTask's "stays active" branch, and cancelTask's
/// "already-active" branch) no longer scale with the size of a task's
/// payloadTx/predicate/auxData, now that they read TaskMetadataLW instead of copying the full
/// TaskMetadata struct from storage.
///
/// Branches that DO delete the task (onCycleSuspend, handleTasksRemoval, stopTask, cancelTask's
/// PENDING branch, dropOrChargeTask's cancelled/expired branch) still legitimately cost more
/// gas for a bigger payload: `delete`-ing a storage struct always clears every field, including
/// the dynamic ones, regardless of what gets copied into memory beforehand. TaskMetadataLW
/// removes the redundant memory copy on those paths too, but can't make deletion itself
/// size-independent, so they are intentionally not covered by a gas-equality assertion here.
contract TaskMetadataLWGasTest is BaseDiamondTest {
    /// @dev Gas tolerance between a "light" and a "heavy" task on the same code path.
    /// Chosen well below the tens-of-thousands of gas that copying ~45KB of extra
    /// payloadTx/predicate/auxData from storage would otherwise cost, so a regression
    /// that reintroduces a full `TaskMetadata memory` copy would fail this assertion.
    uint256 constant GAS_TOLERANCE = 5_000;

    function lightPayload() internal view returns (bytes memory) {
        return createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100));
    }

    /// @dev payloadTx is only length-checked (>= 4 bytes) and decoded at registration time in
    /// this contract set — it is never executed on-chain here (execution happens off-chain via
    /// the VM signer) — so padding the inner call data with junk bytes is a safe way to inflate
    /// its size without affecting any validation.
    function heavyPayload() internal view returns (bytes memory) {
        bytes memory paddedCallData = abi.encodePacked(abi.encodeCall(ERC20SupraHandler.withdraw, 100), new bytes(5_000));
        return createPayload(0, address(erc20SupraHandler), paddedCallData);
    }

    function heavyAuxData() internal pure returns (bytes[] memory auxData) {
        auxData = new bytes[](20);
        for (uint256 i = 0; i < auxData.length; i++) {
            auxData[i] = new bytes(2_000);
        }
    }

    /// @dev Deploys an independent diamond sharing the same ERC20Supra token, so a "light" and a
    /// "heavy" task can each be the sole/last task in their own cycle — avoiding the confound of
    /// cycle-transition-finalization overhead (paid only by whichever task is processed last)
    /// leaking into the payload-size comparison.
    function deploySiblingDiamond() internal returns (address) {
        vm.startPrank(admin);
        Deployment memory dep = LibDiamondUtils.deploy(admin, address(erc20Supra), defaultParams);
        // Raise the default input-size caps so this diamond can accept the intentionally
        // oversized heavyPayload()/heavyAuxData() fixtures used to prove gas-independence.
        IConfigFacet(dep.diamond).updateDataLengthCaps(type(uint16).max, type(uint16).max, type(uint16).max, type(uint16).max);
        vm.stopPrank();
        return dep.diamond;
    }

    /// @dev Registers task index 0 (always the first task on a freshly deployed diamond) as a UST.
    function registerUstOn(address _diamond, bytes memory _payload, bytes[] memory _auxData) internal {
        bytes memory predicate = createPredicate(_diamond);

        vm.startPrank(alice);
        erc20SupraHandler.deposit{value: 100 ether}();
        erc20Supra.approve(_diamond, type(uint256).max);

        IRegistryFacet(_diamond).register(
            _payload,
            predicate,
            uint64(block.timestamp + 2450),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            2,
            _auxData
        );
        vm.stopPrank();
    }

    /// @dev Warps to cycle end, finalizes it, and charges the sole task (index 0) on `_diamond`,
    /// returning the gas used by that single `processTasks` call.
    function chargeSoleTaskAndMeasureGas(address _diamond) internal returns (uint256 gasUsed) {
        (uint64 indexBefore, uint64 startTimeBefore, uint64 durationBefore,) = ICoreFacet(_diamond).getCycleInfo();
        vm.warp(startTimeBefore + durationBefore);

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(_diamond).monitorCycleEnd();

        uint256[] memory tasks = new uint256[](1);
        tasks[0] = 0;

        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        uint256 gasBefore = gasleft();
        ICoreFacet(_diamond).processTasks(indexBefore + 1, tasks);
        gasUsed = gasBefore - gasleft();
    }

    /// @dev Charging an active UST (dropOrChargeTask's "Active UST" branch, which never deletes
    /// the task) must cost essentially the same gas whether the task carries a tiny or a ~45KB
    /// payload.
    function testDropOrChargeTaskGasIndependentOfPayloadSize() public {
        bytes[] memory emptyAux;
        registerUstOn(diamondAddr, lightPayload(), emptyAux);

        address heavyDiamond = deploySiblingDiamond();
        registerUstOn(heavyDiamond, heavyPayload(), heavyAuxData());

        uint256 lightGas = chargeSoleTaskAndMeasureGas(diamondAddr);
        uint256 heavyGas = chargeSoleTaskAndMeasureGas(heavyDiamond);

        assertApproxEqAbs(heavyGas, lightGas, GAS_TOLERANCE);
    }

    /// @dev Cancelling an already-ACTIVE task (LibRegistry.cancelTask's non-PENDING branch,
    /// which only overwrites `taskState` and never deletes the task) must cost the same gas
    /// regardless of payload size.
    function testCancelActiveTaskGasIndependentOfPayloadSize() public {
        bytes[] memory emptyAux;
        registerUstOn(diamondAddr, lightPayload(), emptyAux);

        address heavyDiamond = deploySiblingDiamond();
        registerUstOn(heavyDiamond, heavyPayload(), heavyAuxData());

        chargeSoleTaskAndMeasureGas(diamondAddr);
        chargeSoleTaskAndMeasureGas(heavyDiamond);

        uint64[] memory task = new uint64[](1);
        task[0] = 0;

        vm.prank(alice);
        uint256 gasBeforeLight = gasleft();
        IRegistryFacet(diamondAddr).cancelTasks(task);
        uint256 lightGas = gasBeforeLight - gasleft();

        vm.prank(alice);
        uint256 gasBeforeHeavy = gasleft();
        IRegistryFacet(heavyDiamond).cancelTasks(task);
        uint256 heavyGas = gasBeforeHeavy - gasleft();

        assertApproxEqAbs(heavyGas, lightGas, GAS_TOLERANCE);
    }
}
