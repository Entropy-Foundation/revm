// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {BlockMeta} from "../src/BlockMeta.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployBlockMeta is Script {
    address automationController;
    bytes4 selector;
    address owner;

    function setUp() public {
        automationController = vm.envAddress("AUTOMATION_CONTROLLER");
        selector = bytes4(keccak256("monitorCycleEnd()"));
        owner = vm.envAddress("OWNER");
    }

    function run() public {
        vm.startBroadcast();

        // Deploy BlockMeta implementation
        BlockMeta impl = new BlockMeta();
        console.log("BlockMeta implementation deployed at: ", address(impl));


        // Deploy BlockMeta proxy
        bytes memory initData = abi.encodeCall(BlockMeta.initialize, (owner, 1_000_000));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        console.log("BlockMeta proxy deployed at: ", address(proxy));

        // Register the selector
        BlockMeta(address(proxy)).register(automationController, selector, 100_000);

        vm.stopBroadcast();
    }
}
