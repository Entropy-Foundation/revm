// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {IAutomationRegistry} from "../src/IAutomationRegistry.sol";
import {AutomationRegistry} from "../src/AutomationRegistry.sol";
import {CommonUtils} from "../src/CommonUtils.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LibConfig} from "../src/LibConfig.sol";
import {TxHashPrecompile} from "./TxHashPrecompile.sol";

contract RegisterAutomationTask is Script {
    uint64 taskDurationSecs;
    uint64 automationFeeCap;
    uint128 taskMaxGas;
    uint128 taskGasPriceCap;
    address registry;
    address erc20supra;
    address target;

    address public constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000053555001;
    // Config values loaded from .env file
    function setUp() public {
        taskDurationSecs = uint64(vm.envUint("TASK_DURATION_SEC"));
        taskMaxGas = uint128(vm.envUint("TASK_MAX_GAS"));
        taskGasPriceCap = uint128(vm.envUint("TASK_GAS_PRICE_CAP"));
        registry = vm.envAddress("REGISTRY");
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
        IAutomationRegistry registryImpl = IAutomationRegistry(registry);
        bytes[] memory auxData;
        uint64 taskIdx = registryImpl.getNextTaskIndex();
        console.log("Next task index ", taskIdx);

        bytes memory payload = createPayload(0, target, erc20supra);

        registryImpl.register(
            payload,
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
        LibConfig.AccessListEntry[] memory accessList = new LibConfig.AccessListEntry[](0);
        bytes memory callData = abi.encodeCall(IERC20.transfer, (recipient, 100));
        bytes memory payload = abi.encode(_value, cAddress, callData, accessList);

        return payload;
    }

}

contract CancelAutomationTask is Script {
    address registry;
    uint64 taskIndex;

    address public constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000053555001;
    // Config values loaded from .env file
    function setUp() public {
        registry = vm.envAddress("REGISTRY");
        taskIndex = uint64(vm.envUint("TASK_INDEX"));

        TxHashPrecompile deployed = new TxHashPrecompile();
        vm.etch(TX_HASH_PRECOMPILE, address(deployed).code);
    }

    function run() public {
        vm.startBroadcast();
        AutomationRegistry registryImpl = AutomationRegistry(registry);

        registryImpl.cancelTask( taskIndex);

        vm.stopBroadcast();
    }

}
