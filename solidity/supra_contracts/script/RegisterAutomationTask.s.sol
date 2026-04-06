// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {TxHashPrecompile} from "./TxHashPrecompile.sol";

contract RegisterAutomationTask is Script {
    uint64 taskDurationSecs;
    uint64 automationFeeCap;
    uint128 taskMaxGas;
    uint128 taskGasPriceCap;
    address diamond;
    address erc20supra;
    address target;

    address public constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000053555001;
    // Config values loaded from .env file
    function setUp() public {
        taskDurationSecs = uint64(vm.envUint("TASK_DURATION_SEC"));
        taskMaxGas = uint128(vm.envUint("TASK_MAX_GAS"));
        taskGasPriceCap = uint128(vm.envUint("TASK_GAS_PRICE_CAP"));
        diamond = vm.envAddress("DIAMOND");
        erc20supra = vm.envAddress("ERC20SUPRA");
        target = vm.envAddress("TARGET");
        automationFeeCap = uint64(vm.envUint("TASK_AUTOMATION_FEE_CAP"));

        // Deploy TxHashPrecompile and etch its runtime code at the precompile address
        // Helps with precompilation but not with simulation, so one need to run the script with --skip-simualation flag
        TxHashPrecompile deployed = new TxHashPrecompile();
        vm.etch(TX_HASH_PRECOMPILE, address(deployed).code);
    }

    function run() public {
        vm.startBroadcast();
        IRegistryFacet registryFacet = IRegistryFacet(diamond);
        bytes[] memory auxData;
        uint64 taskIdx = registryFacet.getNextTaskIndex();
        console.log("Next task index ", taskIdx);

        bytes memory payload = createPayload(0, target, erc20supra);
        bytes memory predicate = createPredicate(diamond);

        registryFacet.register(
            payload,
            predicate,
            uint64(block.timestamp + taskDurationSecs),     // Task expires before next cycle
            taskMaxGas,
            taskGasPriceCap,
            automationFeeCap,
            0,
            auxData
        );

        vm.stopBroadcast();
    }

    function createPayload(uint128 _value, address recipient, address cAddress) private pure returns (bytes memory) {
        LibCommon.AccessListEntry[] memory accessList = new LibCommon.AccessListEntry[](0);
        bytes memory callData = abi.encodeCall(IERC20.transfer, (recipient, 100));
        bytes memory payload = abi.encode(_value, cAddress, callData, accessList);

        return payload;
    }

    function createPredicate(address _target) private pure returns (bytes memory) {
        // Create a predicate that checks if registration is enabled
        bytes memory callData = abi.encodeCall(IConfigFacet.isRegistrationEnabled, ());
        return abi.encode(_target, callData);
    }
}

contract CancelAutomationTask is Script {
    address diamond;
    uint64 taskIndex;

    address public constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000053555001;
    // Config values loaded from .env file
    function setUp() public {
        diamond = vm.envAddress("DIAMOND");
        taskIndex = uint64(vm.envUint("TASK_INDEX"));

        TxHashPrecompile deployed = new TxHashPrecompile();
        vm.etch(TX_HASH_PRECOMPILE, address(deployed).code);
    }

    function run() public {
        vm.startBroadcast();
        IRegistryFacet registryFacet = IRegistryFacet(diamond);

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = taskIndex;
        registryFacet.cancelTasks(taskIndexes);

        vm.stopBroadcast();
    }

}
